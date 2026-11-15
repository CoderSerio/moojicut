#import "MCPluginResultController.h"
@interface MCPluginResultController ()
@property (nonatomic, readwrite) NSWindow *window;
@property NSString *text;
@property NSTextField *feedback;
@end
@implementation MCPluginResultController
- (instancetype)initWithResult:(NSDictionary *)result pluginName:(NSString *)name {
    if ((self = [super init])) {
        _text = [result[@"text"] copy];
        _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 540, 360)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
        _window.title = result[@"title"]; _window.releasedWhenClosed = NO; _window.delegate = self;
        _window.restorable = NO; _window.tabbingMode = NSWindowTabbingModeDisallowed;
        NSView *root = _window.contentView;
        NSTextField *source = [NSTextField labelWithString:[NSString stringWithFormat:@"来自插件 · %@", name]];
        source.textColor = NSColor.secondaryLabelColor; source.font = [NSFont systemFontOfSize:12];
        NSScrollView *scroll = [NSScrollView new]; scroll.hasVerticalScroller = YES; scroll.borderType = NSBezelBorder;
        NSTextView *text = [[NSTextView alloc] initWithFrame:NSMakeRect(0,0,490,230)];
        text.editable = NO; text.selectable = YES; text.richText = NO; text.string = _text;
        text.font = [NSFont userFixedPitchFontOfSize:13]; text.textContainerInset = NSMakeSize(12,12);
        text.autoresizingMask = NSViewWidthSizable; text.verticallyResizable = YES; text.horizontallyResizable = NO;
        text.textContainer.widthTracksTextView = YES; scroll.documentView = text;
        NSButton *copy = [NSButton buttonWithTitle:@"复制文本" target:self action:@selector(copyText:)];
        copy.identifier = @"plugin-result-copy";
        _feedback = [NSTextField labelWithString:@"仅在点击复制后写入剪贴板。"];
        _feedback.textColor = NSColor.secondaryLabelColor; _feedback.font = [NSFont systemFontOfSize:11];
        for (NSView *view in @[source,scroll,copy,_feedback]) { view.translatesAutoresizingMaskIntoConstraints = NO; [root addSubview:view]; }
        [NSLayoutConstraint activateConstraints:@[
            [source.topAnchor constraintEqualToAnchor:root.topAnchor constant:18], [source.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:20],
            [source.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-20],
            [scroll.topAnchor constraintEqualToAnchor:source.bottomAnchor constant:12], [scroll.leadingAnchor constraintEqualToAnchor:source.leadingAnchor],
            [scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-20], [scroll.bottomAnchor constraintEqualToAnchor:copy.topAnchor constant:-16],
            [copy.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor], [copy.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-16],
            [_feedback.leadingAnchor constraintEqualToAnchor:source.leadingAnchor], [_feedback.centerYAnchor constraintEqualToAnchor:copy.centerYAnchor],
            [_feedback.trailingAnchor constraintLessThanOrEqualToAnchor:copy.leadingAnchor constant:-12],
        ]];
        _window.minSize = NSMakeSize(430,260); [_window center];
    }
    return self;
}
- (void)show { [self.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES]; }
- (BOOL)copyToPasteboard:(NSPasteboard *)pasteboard {
    [pasteboard clearContents]; BOOL ok = [pasteboard setString:self.text forType:NSPasteboardTypeString];
    self.feedback.stringValue = ok ? @"已复制" : @"复制失败，请重试。"; return ok;
}
- (void)copyText:(__unused id)sender { [self copyToPasteboard:NSPasteboard.generalPasteboard]; }
- (void)close { [self.window close]; }
- (void)windowWillClose:(__unused NSNotification *)note {
    [self.window.parentWindow removeChildWindow:self.window];
    self.window.delegate = nil; if (self.onClose) self.onClose(); self.onClose = nil;
}
@end
