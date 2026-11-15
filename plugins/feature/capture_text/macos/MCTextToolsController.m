#import "MCTextToolsController.h"
#import "MCTranslationBridge.h"

@interface MCTextContentView : NSView
@end
@implementation MCTextContentView
- (void)drawRect:(NSRect)dirtyRect {
    [NSColor.windowBackgroundColor setFill]; NSRectFill(dirtyRect);
}
@end

@interface MCTextScrollView : NSScrollView
@end
@implementation MCTextScrollView
- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer {
    self.layer.cornerRadius = 10; self.layer.borderWidth = 1;
    self.layer.borderColor = NSColor.separatorColor.CGColor;
    self.layer.backgroundColor = NSColor.textBackgroundColor.CGColor;
}
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; self.needsDisplay = YES; }
@end

@interface MCTextResultWindowController : NSWindowController <NSWindowDelegate, NSTextViewDelegate>
@property NSData *png;
@property (copy) BOOL (^isCurrent)(void);
@property (copy) void (^onClose)(void);
@property id<MCTextRecognizing> recognizer;
@property id<MCTextRecognitionTask> recognition;
@property NSViewController<MCTextTranslating> *translator;
@property NSTextView *sourceText;
@property NSTextView *resultText;
@property NSTextField *status;
@property NSPopUpButton *sourceLanguage;
@property NSPopUpButton *targetLanguage;
@property NSButton *translateButton;
@property NSButton *currentCopyButton;
@property NSSegmentedControl *contentSelector;
@property NSTabView *contentPages;
@property NSProgressIndicator *progress;
@property NSButton *cancelButton;
@property NSButton *retryButton;
@property NSTimer *leaseTimer;
@property NSUInteger generation;
@property BOOL closed;
@property BOOL recognizing;
@property BOOL translating;
@end

@implementation MCTextResultWindowController
static NSScrollView *MCTextScroll(NSTextView **output, NSString *identifier) {
    NSScrollView *scroll = [MCTextScrollView new];
    scroll.hasVerticalScroller = YES; scroll.autohidesScrollers = YES; scroll.borderType = NSNoBorder;
    scroll.wantsLayer = YES; scroll.layer.cornerRadius = 10; scroll.layer.masksToBounds = YES;
    NSTextView *text = [[NSTextView alloc] initWithFrame:NSMakeRect(0,0,560,170)];
    text.richText = NO; text.allowsUndo = YES; text.font = [NSFont systemFontOfSize:14];
    text.identifier = identifier; text.textContainerInset = NSMakeSize(14,14);
    text.textColor = NSColor.textColor; text.backgroundColor = NSColor.textBackgroundColor;
    text.verticallyResizable = YES; text.horizontallyResizable = NO;
    text.autoresizingMask = NSViewWidthSizable;
    text.textContainer.widthTracksTextView = YES;
    scroll.documentView = text; *output = text; return scroll;
}
- (instancetype)initWithPNGData:(NSData *)png isCurrent:(BOOL (^)(void))isCurrent {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,600,530)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    if ((self = [super initWithWindow:window])) {
        _png = [png copy]; _isCurrent = [isCurrent copy]; _recognizer = [MCTextRecognitionService new];
        window.title = @"截图文字"; window.releasedWhenClosed = NO; window.restorable = NO;
        window.delegate = self; window.tabbingMode = NSWindowTabbingModeDisallowed;
        window.minSize = NSMakeSize(540,490);
        _translator = [MCTranslationBridge new];
        NSViewController *content = [NSViewController new];
        content.view = [[MCTextContentView alloc] initWithFrame:window.contentView.bounds];
        window.contentViewController = content; [content addChildViewController:_translator];
        NSView *root = content.view;
        NSTextField *heading = [NSTextField labelWithString:@"截图文字"];
        heading.font = [NSFont systemFontOfSize:21 weight:NSFontWeightSemibold];
        NSTextField *privacy = [NSTextField labelWithString:@"本机识别与翻译 · 首次翻译可能需要下载语言资源"];
        privacy.font = [NSFont systemFontOfSize:11]; privacy.textColor = NSColor.secondaryLabelColor;
        NSTextView *source = nil, *result = nil;
        NSScrollView *sourceScroll = MCTextScroll(&source, @"capture-text-source");
        NSScrollView *resultScroll = MCTextScroll(&result, @"capture-text-result");
        _sourceText = source; _resultText = result; _sourceText.delegate = self; _resultText.delegate = self;
        _sourceText.accessibilityLabel = @"识别原文，可编辑"; _resultText.accessibilityLabel = @"翻译结果，可编辑";
        _contentSelector = [NSSegmentedControl segmentedControlWithLabels:@[@"原文", @"译文"]
            trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(selectContent:)];
        _contentSelector.selectedSegment = 0; _contentSelector.accessibilityLabel = @"文字内容";
        _contentPages = [[NSTabView alloc] initWithFrame:NSZeroRect]; _contentPages.tabViewType = NSNoTabsNoBorder;
        for (NSScrollView *scroll in @[sourceScroll, resultScroll]) {
            NSTabViewItem *page = [[NSTabViewItem alloc] initWithIdentifier:scroll == sourceScroll ? @"source" : @"translation"];
            page.view = scroll; [_contentPages addTabViewItem:page];
        }
        _sourceLanguage = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        [_sourceLanguage addItemWithTitle:@"自动识别"]; _sourceLanguage.lastItem.representedObject = @"";
        _targetLanguage = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        for (NSPopUpButton *popup in @[_sourceLanguage, _targetLanguage]) {
            [popup addItemWithTitle:@"简体中文"]; popup.lastItem.representedObject = @"zh-Hans";
            [popup addItemWithTitle:@"English"]; popup.lastItem.representedObject = @"en";
            popup.target = self; popup.action = @selector(languageChanged:);
        }
        _sourceLanguage.identifier = @"capture-text-source-language"; _sourceLanguage.accessibilityLabel = @"原文语言";
        _targetLanguage.identifier = @"capture-text-target-language"; _targetLanguage.accessibilityLabel = @"目标语言";
        NSTextField *arrow = [NSTextField labelWithString:@"→"]; arrow.textColor = NSColor.secondaryLabelColor;
        _translateButton = [NSButton buttonWithTitle:@"翻译" target:self action:@selector(translate:)];
        _translateButton.identifier = @"capture-text-translate";
        _retryButton = [NSButton buttonWithTitle:@"重新识别" target:self action:@selector(retry:)];
        _retryButton.bordered = NO; _retryButton.contentTintColor = NSColor.secondaryLabelColor;
        _cancelButton = [NSButton buttonWithTitle:@"取消" target:self action:@selector(cancelTask:)];
        _currentCopyButton = [NSButton buttonWithTitle:@"复制原文" target:self action:@selector(copyCurrent:)];
        _currentCopyButton.bezelStyle = NSBezelStyleRounded; _currentCopyButton.controlSize = NSControlSizeLarge;
        _currentCopyButton.keyEquivalent = @"c"; _currentCopyButton.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
        _currentCopyButton.toolTip = @"复制当前内容（⇧⌘C）";
        _status = [NSTextField wrappingLabelWithString:@"正在识别截图中的文字…"];
        _status.textColor = NSColor.secondaryLabelColor; _status.font = [NSFont systemFontOfSize:12];
        _status.maximumNumberOfLines = 3;
        _progress = [NSProgressIndicator new]; _progress.style = NSProgressIndicatorStyleSpinning;
        _progress.controlSize = NSControlSizeSmall; _progress.displayedWhenStopped = NO;
        NSView *bridge = _translator.view;
        NSArray<NSView *> *views = @[heading,privacy,_contentSelector,_contentPages,_sourceLanguage,_targetLanguage,arrow,
            _translateButton,_retryButton,_cancelButton,_currentCopyButton,_status,_progress,bridge];
        for (NSView *view in views) { view.translatesAutoresizingMaskIntoConstraints = NO; [root addSubview:view]; }
        [NSLayoutConstraint activateConstraints:@[
            [heading.topAnchor constraintEqualToAnchor:root.topAnchor constant:22], [heading.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:24],
            [privacy.topAnchor constraintEqualToAnchor:heading.bottomAnchor constant:6], [privacy.leadingAnchor constraintEqualToAnchor:heading.leadingAnchor],
            [privacy.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-24],
            [_contentSelector.topAnchor constraintEqualToAnchor:privacy.bottomAnchor constant:20], [_contentSelector.leadingAnchor constraintEqualToAnchor:heading.leadingAnchor],
            [_retryButton.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-24], [_retryButton.centerYAnchor constraintEqualToAnchor:_contentSelector.centerYAnchor],
            [_contentPages.topAnchor constraintEqualToAnchor:_contentSelector.bottomAnchor constant:12], [_contentPages.leadingAnchor constraintEqualToAnchor:heading.leadingAnchor],
            [_contentPages.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-24], [_contentPages.heightAnchor constraintGreaterThanOrEqualToConstant:180],
            [_sourceLanguage.topAnchor constraintEqualToAnchor:_contentPages.bottomAnchor constant:14], [_sourceLanguage.leadingAnchor constraintEqualToAnchor:heading.leadingAnchor],
            [_sourceLanguage.widthAnchor constraintEqualToConstant:150], [arrow.leadingAnchor constraintEqualToAnchor:_sourceLanguage.trailingAnchor constant:8],
            [arrow.centerYAnchor constraintEqualToAnchor:_sourceLanguage.centerYAnchor], [_targetLanguage.leadingAnchor constraintEqualToAnchor:arrow.trailingAnchor constant:8],
            [_targetLanguage.widthAnchor constraintEqualToConstant:150], [_targetLanguage.centerYAnchor constraintEqualToAnchor:arrow.centerYAnchor],
            [_translateButton.trailingAnchor constraintEqualToAnchor:_contentPages.trailingAnchor], [_translateButton.centerYAnchor constraintEqualToAnchor:arrow.centerYAnchor],
            [_translateButton.leadingAnchor constraintGreaterThanOrEqualToAnchor:_targetLanguage.trailingAnchor constant:12],
            [_progress.leadingAnchor constraintEqualToAnchor:heading.leadingAnchor], [_progress.topAnchor constraintEqualToAnchor:_sourceLanguage.bottomAnchor constant:18],
            [_progress.widthAnchor constraintEqualToConstant:16], [_progress.heightAnchor constraintEqualToConstant:16],
            [_status.topAnchor constraintEqualToAnchor:_progress.topAnchor], [_status.leadingAnchor constraintEqualToAnchor:_progress.trailingAnchor constant:8],
            [_status.trailingAnchor constraintEqualToAnchor:_contentPages.trailingAnchor], [_status.heightAnchor constraintGreaterThanOrEqualToConstant:34],
            [_currentCopyButton.topAnchor constraintEqualToAnchor:_status.bottomAnchor constant:14], [_currentCopyButton.trailingAnchor constraintEqualToAnchor:_contentPages.trailingAnchor],
            [_currentCopyButton.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-20],
            [_cancelButton.leadingAnchor constraintEqualToAnchor:heading.leadingAnchor], [_cancelButton.centerYAnchor constraintEqualToAnchor:_currentCopyButton.centerYAnchor],
            [bridge.leadingAnchor constraintEqualToAnchor:root.leadingAnchor], [bridge.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
            [bridge.widthAnchor constraintEqualToConstant:1], [bridge.heightAnchor constraintEqualToConstant:1],
        ]];
        __weak typeof(self) weakSelf = self;
        [MCTranslationBridge supportedLanguagesWithCompletion:^(NSArray<NSDictionary<NSString *,NSString *> *> *languages) {
            typeof(self) self = weakSelf; if (!self || self.closed) return;
            for (NSPopUpButton *popup in @[self.sourceLanguage,self.targetLanguage]) {
                for (NSDictionary *language in languages) {
                    NSString *identifier = language[@"id"];
                    BOOL exists = NO;
                    for (NSMenuItem *item in popup.itemArray) if ([item.representedObject isEqual:identifier]) exists = YES;
                    if (identifier.length && !exists) {
                        [popup addItemWithTitle:language[@"name"] ?: identifier]; popup.lastItem.representedObject = identifier;
                    }
                }
            }
        }];
        _leaseTimer = [NSTimer timerWithTimeInterval:0.2 repeats:YES block:^(__unused NSTimer *timer) { [weakSelf validateLease]; }];
        [NSRunLoop.mainRunLoop addTimer:_leaseTimer forMode:NSRunLoopCommonModes];
        [self refreshButtons];
    }
    return self;
}
- (BOOL)validateLease {
    if (self.closed) return NO;
    if (!self.isCurrent || !self.isCurrent()) { [self close]; return NO; }
    return YES;
}
- (void)selectContent:(__unused id)sender {
    [self.contentPages selectTabViewItemAtIndex:self.contentSelector.selectedSegment];
    [self refreshButtons];
}
- (void)setStatus:(NSString *)status error:(BOOL)error {
    self.status.stringValue = status; self.status.toolTip = status;
    self.status.textColor = error ? NSColor.systemRedColor : NSColor.secondaryLabelColor;
    if (error) NSAccessibilityPostNotification(self.status, NSAccessibilityValueChangedNotification);
}
- (void)refreshButtons {
    BOOL text = self.sourceText.string.length > 0;
    BOOL busy = self.recognizing || self.translating;
    BOOL hasTranslation = self.resultText.string.length > 0;
    [self.contentSelector setEnabled:hasTranslation || self.translating forSegment:1];
    if (!hasTranslation && !self.translating && self.contentSelector.selectedSegment == 1) {
        self.contentSelector.selectedSegment = 0; [self.contentPages selectTabViewItemAtIndex:0];
    }
    BOOL translated = self.contentSelector.selectedSegment == 1;
    self.translateButton.enabled = text && !busy;
    self.retryButton.enabled = !busy;
    self.currentCopyButton.title = translated ? @"复制译文" : @"复制原文";
    self.currentCopyButton.enabled = translated ? hasTranslation && !self.translating : text && !self.recognizing;
    self.cancelButton.enabled = busy; self.cancelButton.hidden = !busy;
    self.progress.hidden = !busy;
    if (busy) [self.progress startAnimation:nil]; else [self.progress stopAnimation:nil];
    self.sourceText.editable = !self.recognizing;
    self.resultText.editable = !busy;
}
- (void)invalidateWork {
    self.generation++;
    [self.recognition cancel]; self.recognition = nil;
    [self.translator cancel]; self.recognizing = NO; self.translating = NO;
}
- (void)recognizeAndTranslate:(BOOL)translate {
    if (![self validateLease]) return;
    [self invalidateWork]; NSUInteger generation = self.generation;
    self.recognizing = YES;
    self.contentSelector.selectedSegment = 0; [self.contentPages selectTabViewItemAtIndex:0];
    [self setStatus:@"正在识别…" error:NO]; [self refreshButtons];
    __weak typeof(self) weakSelf = self;
    self.recognition = [self.recognizer recognizePNGData:self.png completion:^(NSString *text, NSError *error) {
        typeof(self) self = weakSelf;
        if (!self || generation != self.generation || ![self validateLease]) return;
        self.recognition = nil; self.recognizing = NO;
        // A retry only replaces edited text after a successful recognition.
        // Cancellation and errors must not discard the user's correction.
        if (!error) { self.sourceText.string = text ?: @""; self.resultText.string = @""; }
        [self setStatus:error ? error.localizedDescription : text.length ? @"识别完成，可直接复制或修改原文。需要译文时，选择语言后点「翻译」。" : @"没有识别到文字。可以手动输入，或重新框选截图。" error:error != nil];
        [self refreshButtons];
        if (!error && text.length && translate) [self translate:nil];
    }];
}
- (void)retry:(__unused id)sender { [self recognizeAndTranslate:NO]; }
- (void)translate:(__unused id)sender {
    if (![self validateLease] || self.recognizing) return;
    NSString *text = [self.sourceText.string copy];
    if (![text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length) {
        [self setStatus:@"请先输入或识别需要翻译的文字。" error:YES]; return;
    }
    [self invalidateWork]; NSUInteger generation = self.generation;
    self.translating = YES; self.resultText.string = @"";
    self.contentSelector.selectedSegment = 1; [self.contentPages selectTabViewItemAtIndex:1];
    [self setStatus:@"正在本机翻译…首次使用请确认系统的语言资源下载。" error:NO]; [self refreshButtons];
    NSString *source = self.sourceLanguage.selectedItem.representedObject;
    NSString *target = self.targetLanguage.selectedItem.representedObject;
    __weak typeof(self) weakSelf = self;
    [self.translator translateText:text sourceLanguage:source.length ? source : nil targetLanguage:target
        completion:^(NSString *translated, NSString *resolvedSource, NSError *error) {
            (void)resolvedSource;
            typeof(self) self = weakSelf;
            if (!self || generation != self.generation || ![self validateLease]) return;
            self.translating = NO; self.resultText.string = translated ?: @"";
            [self setStatus:error ? error.localizedDescription : @"翻译完成，可修改译文后复制。" error:error != nil];
            [self refreshButtons];
        }];
}
- (void)languageChanged:(__unused id)sender {
    if (self.translating) [self invalidateWork];
    self.resultText.string = @"";
    if (!self.recognizing) [self setStatus:@"语言已更改，点击「翻译」生成译文。" error:NO];
    [self refreshButtons];
}
- (void)textDidChange:(NSNotification *)notification {
    if (notification.object == self.resultText) { [self refreshButtons]; return; }
    if (notification.object != self.sourceText || self.recognizing) return;
    if (self.translating) [self invalidateWork];
    self.resultText.string = @""; [self setStatus:@"原文已修改，可以复制或重新翻译。" error:NO]; [self refreshButtons];
}
- (void)cancelTask:(__unused id)sender {
    [self invalidateWork]; [self setStatus:@"已取消，可继续编辑或重试。" error:NO]; [self refreshButtons];
}
- (BOOL)copyText:(NSString *)text toPasteboard:(NSPasteboard *)pasteboard {
    if (![self validateLease] || !text.length) return NO;
    [pasteboard clearContents]; BOOL copied = [pasteboard setString:text forType:NSPasteboardTypeString];
    [self setStatus:copied ? @"已复制" : @"复制失败，请重试。" error:!copied]; return copied;
}
- (void)copyCurrent:(__unused id)sender {
    NSString *text = self.contentSelector.selectedSegment == 1 ? self.resultText.string : self.sourceText.string;
    if (self.currentCopyButton.enabled) [self copyText:text toPasteboard:NSPasteboard.generalPasteboard];
}
- (void)parentWillClose:(__unused NSNotification *)notification { [self close]; }
- (void)windowWillClose:(__unused NSNotification *)notification {
    if (self.closed) return;
    self.closed = YES; [self invalidateWork]; [self.leaseTimer invalidate]; self.leaseTimer = nil;
    [self.window.parentWindow removeChildWindow:self.window];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    self.isCurrent = nil; self.png = nil;
    self.sourceText.string = @""; self.resultText.string = @"";
    void (^closed)(void) = self.onClose; self.onClose = nil; if (closed) closed();
}
- (void)dealloc { [_leaseTimer invalidate]; [_recognition cancel]; }
@end

@interface MCTextToolsController ()
@property NSMutableDictionary<NSString *,MCTextResultWindowController *> *results;
@end
@implementation MCTextToolsController
- (instancetype)init { if ((self = [super init])) _results = [NSMutableDictionary dictionary]; return self; }
- (void)openPNGData:(NSData *)data owner:(NSString *)owner parentWindow:(NSWindow *)window
         isCurrent:(BOOL (^)(void))isCurrent translate:(BOOL)translate {
    NSAssert(NSThread.isMainThread, @"Text tools must be opened on the main thread");
    if (!data.length || !owner.length || !window || !isCurrent || !isCurrent()) return;
    [self cancelForOwner:owner];
    MCTextResultWindowController *result = [[MCTextResultWindowController alloc] initWithPNGData:data isCurrent:isCurrent];
    __weak typeof(self) weakSelf = self;
    result.onClose = ^{ [weakSelf.results removeObjectForKey:owner]; };
    self.results[owner] = result;
    result.window.level = window.level;
    [window addChildWindow:result.window ordered:NSWindowAbove];
    [result.window center]; [result showWindow:nil]; [result.window makeKeyAndOrderFront:nil];
    [[NSNotificationCenter defaultCenter] addObserver:result selector:@selector(parentWillClose:) name:NSWindowWillCloseNotification object:window];
    [result recognizeAndTranslate:translate];
}
- (void)cancelForOwner:(NSString *)owner { [self.results[owner] close]; }
- (void)cancelAll { for (MCTextResultWindowController *result in self.results.allValues) [result close]; }
- (void)dealloc { for (MCTextResultWindowController *result in _results.allValues) { result.onClose = nil; [result close]; } }
@end
