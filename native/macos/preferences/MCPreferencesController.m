#import "MCPreferencesController.h"
#import "MCShortcutRecorder.h"
#import "../updates/MCUpdateController.h"

static NSString *const MCAppearanceKey = @"appearance";
static NSTextField *MCLabel(NSString *text, CGFloat size, BOOL secondary) {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.font = [NSFont systemFontOfSize:size];
    label.textColor = secondary ? NSColor.secondaryLabelColor : NSColor.labelColor;
    return label;
}
static NSTextField *MCHeading(NSString *text) {
    NSTextField *label = MCLabel(text, 13, NO); label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]; return label;
}
static NSStackView *MCStack(NSArray<NSView *> *views, NSUserInterfaceLayoutOrientation orientation, CGFloat spacing) {
    NSStackView *stack = [NSStackView stackViewWithViews:views];
    stack.orientation = orientation; stack.spacing = spacing;
    stack.alignment = orientation == NSUserInterfaceLayoutOrientationVertical ? NSLayoutAttributeLeading : NSLayoutAttributeCenterY;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    return stack;
}
static void MCPin(NSView *view, NSView *container) {
    [container addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [view.topAnchor constraintEqualToAnchor:container.topAnchor constant:24],
        [view.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:24],
        [view.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-24],
        [view.bottomAnchor constraintLessThanOrEqualToAnchor:container.bottomAnchor constant:-24]
    ]];
}
static NSGridView *MCGrid(NSArray<NSArray<NSView *> *> *rows) {
    NSGridView *grid = [NSGridView gridViewWithViews:rows];
    grid.rowSpacing = 10; grid.columnSpacing = 12; grid.xPlacement = NSGridCellPlacementLeading; grid.yPlacement = NSGridCellPlacementCenter;
    [grid columnAtIndex:0].width = 72;
    return grid;
}

@interface MCPreferencesController ()
@property (nonatomic, readwrite, nullable) NSWindow *window;
@property NSUserDefaults *defaults;
@property NSString *coreVersion;
@property NSDictionary *diagnostics;
@property NSTabView *pages;
@property NSPopUpButton *appearancePopup;
@property NSView *technicalDetails;
@property NSButton *disclosure;
@property (nonatomic, readwrite) MCShortcutStore *shortcutStore;
@property NSMutableDictionary<NSString *, MCShortcutRecorder *> *shortcutRecorders;
@property NSMutableDictionary<NSString *, NSButton *> *shortcutClearButtons;
@property NSTextField *shortcutFeedback;
@property NSTextField *shortcutAvailability;
@property NSButton *automaticUpdatesCheckbox;
@property NSButton *checkUpdatesButton;
@property NSTextField *updateStatus;
@end

@implementation MCPreferencesController
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults coreVersion:(NSString *)coreVersion diagnostics:(NSDictionary *)diagnostics {
    if ((self = [super init])) { _defaults = defaults; _coreVersion = coreVersion; _diagnostics = diagnostics; _shortcutStore = [[MCShortcutStore alloc] initWithDefaults:defaults]; }
    return self;
}
+ (void)applySavedAppearance:(NSUserDefaults *)defaults {
    NSString *choice = [defaults stringForKey:MCAppearanceKey] ?: @"system";
    NSApp.appearance = [choice isEqualToString:@"dark"] ? [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua] :
        [choice isEqualToString:@"light"] ? [NSAppearance appearanceNamed:NSAppearanceNameAqua] : nil;
}
- (NSString *)appearanceChoice { return [self.defaults stringForKey:MCAppearanceKey] ?: @"system"; }
- (BOOL)technicalDetailsVisible { return self.technicalDetails && !self.technicalDetails.hidden; }
- (void)buildWindow {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 560, 340)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Mooji Cut 设置"; window.releasedWhenClosed = NO; window.delegate = self;
    window.restorable = NO; window.tabbingMode = NSWindowTabbingModeDisallowed;
    window.toolbarStyle = NSWindowToolbarStylePreference;
    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"MoojiCutPreferences"];
    toolbar.delegate = self; toolbar.allowsUserCustomization = NO; toolbar.autosavesConfiguration = NO;
    toolbar.displayMode = NSToolbarDisplayModeIconAndLabel; window.toolbar = toolbar;
    self.window = window;
    NSTabView *pages = [[NSTabView alloc] initWithFrame:window.contentView.bounds];
    pages.tabViewType = NSNoTabsNoBorder; pages.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NSTabViewItem *general = [[NSTabViewItem alloc] initWithIdentifier:@"general"]; general.label = @"通用"; general.view = [self generalPage];
    NSTabViewItem *shortcuts = [[NSTabViewItem alloc] initWithIdentifier:@"shortcuts"]; shortcuts.label = @"快捷键"; shortcuts.view = [self shortcutsPage];
    NSTabViewItem *about = [[NSTabViewItem alloc] initWithIdentifier:@"about"]; about.label = @"关于"; about.view = [self aboutPage];
    NSTabViewItem *updates = [[NSTabViewItem alloc] initWithIdentifier:@"updates"]; updates.label = @"更新"; updates.view = [self updatesPage];
    [pages addTabViewItem:general]; [pages addTabViewItem:shortcuts]; [pages addTabViewItem:about]; [pages addTabViewItem:updates]; [window.contentView addSubview:pages]; self.pages = pages;
    [self selectPage:@"general"]; [window center];
}
- (NSView *)generalPage {
    NSView *page = [NSView new];
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [popup addItemsWithTitles:@[@"跟随系统", @"浅色", @"深色"]];
    popup.target = self; popup.action = @selector(appearanceChanged:); self.appearancePopup = popup;
    NSInteger index = [@[@"system", @"light", @"dark"] indexOfObject:self.appearanceChoice];
    [popup selectItemAtIndex:index == NSNotFound ? 0 : index];
    [popup.widthAnchor constraintEqualToConstant:190].active = YES;
    NSTextField *description = MCLabel(@"跟随系统时，Mooji Cut 使用当前 macOS 外观。", 12, YES);
    NSGridView *grid = MCGrid(@[@[MCLabel(@"主题", 13, NO), popup], @[NSGridCell.emptyContentView, description]]);
    NSBox *separator = [NSBox new]; separator.boxType = NSBoxSeparator;
    NSTextField *background = MCLabel(@"关闭设置窗口后，Mooji Cut 会继续在菜单栏运行。", 13, NO);
    NSStackView *stack = MCStack(@[MCHeading(@"外观"), grid, separator, MCHeading(@"后台运行"), background, MCLabel(@"设置会自动保存。", 11, YES)], NSUserInterfaceLayoutOrientationVertical, 14);
    [stack setCustomSpacing:22 afterView:grid]; [stack setCustomSpacing:22 afterView:separator]; [stack setCustomSpacing:30 afterView:background];
    [separator.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    MCPin(stack, page); return page;
}
- (void)setShortcutFeedback:(NSString *)message error:(BOOL)error {
    self.shortcutFeedback.stringValue = message;
    self.shortcutFeedback.textColor = error ? NSColor.systemRedColor : NSColor.secondaryLabelColor;
    if (error) NSAccessibilityPostNotification(self.shortcutFeedback, NSAccessibilityValueChangedNotification);
}
- (void)cancelShortcutRecording {
    for (MCShortcutRecorder *recorder in self.shortcutRecorders.allValues) [recorder cancelRecording];
}
- (void)setShortcutRegistrationError:(NSString *)error {
    _shortcutRegistrationError = [error copy];
    [self updateShortcutAvailability];
}
- (void)updateShortcutAvailability {
    NSMutableArray<NSString *> *states = [NSMutableArray array];
    NSDictionary *names = @{@"capture":@"截图", @"record":@"开始录屏", @"stop":@"停止录屏"};
    for (NSString *action in @[@"capture", @"record", @"stop"])
        [states addObject:[NSString stringWithFormat:@"%@%@", names[action], [self.shortcutStore shortcutForAction:action] ? @"已启用" : @"未设置"]];
    NSString *availability = self.shortcutRegistrationError ?: [states componentsJoinedByString:@" · "];
    self.shortcutAvailability.stringValue = [availability stringByAppendingString:@"\n录入时暂时停用全部快捷键，结束录入后自动恢复。"];
    self.shortcutAvailability.textColor = self.shortcutRegistrationError ? NSColor.systemRedColor : NSColor.secondaryLabelColor;
}
- (void)notifyShortcutRecordingState {
    BOOL recording = NO;
    for (MCShortcutRecorder *recorder in self.shortcutRecorders.allValues) recording = recording || recorder.isRecording;
    if (self.onShortcutRecordingChanged) self.onShortcutRecordingChanged(recording);
}
- (NSView *)shortcutsPage {
    NSView *page = [NSView new];
    self.shortcutRecorders = [NSMutableDictionary dictionary];
    self.shortcutClearButtons = [NSMutableDictionary dictionary];
    NSMutableArray *rows = [NSMutableArray array];
    NSArray *actions = @[@"capture", @"record", @"stop"];
    NSArray *names = @[@"截图", @"开始录屏", @"停止录屏"];
    __weak MCPreferencesController *weakSelf = self;
    for (NSUInteger index = 0; index < actions.count; index++) {
        NSString *action = actions[index]; NSString *name = names[index];
        MCShortcutRecorder *recorder = [[MCShortcutRecorder alloc] initWithFrame:NSZeroRect];
        recorder.shortcut = [self.shortcutStore shortcutForAction:action];
        recorder.accessibilityLabel = [name stringByAppendingString:@"快捷键"];
        [recorder.widthAnchor constraintEqualToConstant:320].active = YES;
        [recorder.heightAnchor constraintEqualToConstant:28].active = YES;
        recorder.onChange = ^BOOL(NSDictionary *shortcut) {
            MCPreferencesController *controller = weakSelf; if (!controller) return NO;
            NSString *error = nil;
            if (![controller.shortcutStore setShortcut:shortcut forAction:action error:&error]) {
                [controller setShortcutFeedback:error ?: @"无法保存这个快捷键。" error:YES]; return NO;
            }
            controller.shortcutClearButtons[action].enabled = shortcut != nil;
            [controller updateShortcutAvailability];
            [controller setShortcutFeedback:shortcut ? @"快捷键已保存。" : @"已清除这个快捷键。" error:NO];
            return YES;
        };
        recorder.onError = ^(NSString *message) { [weakSelf setShortcutFeedback:message error:YES]; };
        recorder.onRecordingChanged = ^(BOOL recording) {
            MCPreferencesController *controller = weakSelf;
            if (!recording) {
                [controller notifyShortcutRecordingState];
                if ([controller.shortcutFeedback.stringValue hasPrefix:@"按下"] || [controller.shortcutFeedback.textColor isEqual:NSColor.systemRedColor])
                    [controller setShortcutFeedback:@"录入已结束，未更改的快捷键保持原样。" error:NO];
                return;
            }
            for (NSString *other in controller.shortcutRecorders) if (![other isEqual:action]) [controller.shortcutRecorders[other] cancelRecording];
            [controller notifyShortcutRecordingState];
            [controller setShortcutFeedback:@"按下组合键；Esc 取消，Delete 清除。" error:NO];
        };
        NSButton *clear = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"xmark.circle.fill" accessibilityDescription:@"清除"] target:self action:@selector(clearShortcut:)];
        clear.bordered = NO; clear.contentTintColor = NSColor.tertiaryLabelColor;
        clear.identifier = action; clear.toolTip = [@"清除" stringByAppendingString:name]; clear.accessibilityLabel = [name stringByAppendingString:@"：清除快捷键"];
        clear.enabled = recorder.shortcut != nil;
        [clear.widthAnchor constraintEqualToConstant:24].active = YES;
        self.shortcutRecorders[action] = recorder; self.shortcutClearButtons[action] = clear;
        [rows addObject:@[MCLabel(name, 13, NO), recorder, clear]];
    }
    NSGridView *grid = MCGrid(rows); grid.rowSpacing = 8;
    NSTextField *feedback = MCLabel(@"Esc 取消录入，Delete 清除。设置会自动保存。", 12, YES);
    [feedback.heightAnchor constraintGreaterThanOrEqualToConstant:30].active = YES; self.shortcutFeedback = feedback;
    NSButton *reset = [NSButton buttonWithTitle:@"恢复默认" target:self action:@selector(resetShortcuts:)];
    reset.bezelStyle = NSBezelStyleRounded; reset.accessibilityLabel = @"恢复所有快捷键为默认值";
    NSView *spacer = [NSView new];
    NSStackView *resetRow = MCStack(@[spacer, reset], NSUserInterfaceLayoutOrientationHorizontal, 0);
    [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [reset setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSTextField *availability = MCLabel(@"", 11, YES); self.shortcutAvailability = availability;
    [self updateShortcutAvailability];
    NSStackView *stack = MCStack(@[MCHeading(@"全局快捷键"), MCLabel(@"点按按键框，然后按下你想使用的组合键。", 12, YES), grid, feedback, resetRow, availability], NSUserInterfaceLayoutOrientationVertical, 12);
    [resetRow.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    [feedback.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    [availability.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    MCPin(stack, page); return page;
}
- (void)clearShortcut:(NSButton *)sender {
    [self cancelShortcutRecording];
    NSString *action = sender.identifier; NSString *error = nil;
    if ([self.shortcutStore setShortcut:nil forAction:action error:&error]) {
        self.shortcutRecorders[action].shortcut = nil; sender.enabled = NO;
        [self updateShortcutAvailability];
        [self setShortcutFeedback:@"已清除这个快捷键。" error:NO];
    } else [self setShortcutFeedback:error ?: @"无法清除快捷键。" error:YES];
}
- (void)resetShortcuts:(__unused id)sender {
    [self cancelShortcutRecording]; NSString *error = nil;
    if (![self.shortcutStore restoreDefaultsWithError:&error]) {
        [self setShortcutFeedback:error ?: @"无法恢复默认快捷键。" error:YES]; return;
    }
    for (NSString *action in self.shortcutRecorders) {
        self.shortcutRecorders[action].shortcut = [self.shortcutStore shortcutForAction:action];
        self.shortcutClearButtons[action].enabled = YES;
    }
    [self updateShortcutAvailability];
    [self setShortcutFeedback:@"已恢复默认快捷键。" error:NO];
}
- (NSView *)aboutPage {
    NSView *page = [NSView new];
    NSImageView *icon = [[NSImageView alloc] initWithFrame:NSZeroRect];
    icon.image = NSApp.applicationIconImage;
    icon.accessibilityLabel = @"Mooji Cut 眨眼取景框标志";
    [icon.widthAnchor constraintEqualToConstant:56].active = YES; [icon.heightAnchor constraintEqualToConstant:56].active = YES;
    NSTextField *name = MCLabel(@"Mooji Cut", 21, NO); name.font = [NSFont systemFontOfSize:21 weight:NSFontWeightSemibold];
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"MoojiCutReleaseVersion"] ?: [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"开发版本";
    NSStackView *identity = MCStack(@[name, MCLabel([@"版本 " stringByAppendingString:version], 12, YES)], NSUserInterfaceLayoutOrientationVertical, 4);
    NSStackView *header = MCStack(@[icon, identity], NSUserInterfaceLayoutOrientationHorizontal, 16);
    NSButton *disclosure = [NSButton new]; disclosure.bezelStyle = NSBezelStyleDisclosure; disclosure.buttonType = NSButtonTypeOnOff;
    disclosure.title = @""; disclosure.target = self; disclosure.action = @selector(toggleTechnicalDetails:); disclosure.accessibilityLabel = @"展开技术信息";
    self.disclosure = disclosure;
    NSStackView *disclosureRow = MCStack(@[disclosure, MCLabel(@"技术信息", 12, YES)], NSUserInterfaceLayoutOrientationHorizontal, 4);
    NSString *arch = @"arm64";
#if defined(__x86_64__)
    arch = @"x86_64";
#endif
    NSString *core = [NSString stringWithFormat:@"MoonBit Native · %@", self.coreVersion];
    NSGridView *details = MCGrid(@[
        @[MCLabel(@"核心", 12, YES), MCLabel(core, 12, NO)],
        @[MCLabel(@"宿主", 12, YES), MCLabel([@"AppKit · " stringByAppendingString:arch], 12, NO)],
        @[MCLabel(@"状态", 12, YES), MCLabel([self.diagnostics[@"passed"] boolValue] ? @"核心连接正常" : @"核心连接未通过检查", 12, NO)],
        @[MCLabel(@"当前范围", 12, YES), MCLabel(@"截图标注、录屏剪辑与确认复制。", 12, NO)]
    ]);
    details.hidden = YES; self.technicalDetails = details;
    NSStackView *stack = MCStack(@[header, MCLabel(@"这一幕，我截下了。", 13, NO), MCLabel(@"截图标注与录屏剪辑，确认后复制。", 12, YES), disclosureRow, details], NSUserInterfaceLayoutOrientationVertical, 18);
    stack.detachesHiddenViews = YES; MCPin(stack, page); return page;
}
- (void)appearanceChanged:(NSPopUpButton *)sender {
    NSArray *values = @[@"system", @"light", @"dark"];
    [self setAppearanceChoice:values[(NSUInteger)sender.indexOfSelectedItem]];
}
- (void)setUpdateController:(MCUpdateController *)controller {
    if (_updateController == controller) return;
    if (_updateController) [NSNotificationCenter.defaultCenter removeObserver:self name:MCUpdateStateDidChangeNotification object:_updateController];
    _updateController = controller;
    if (controller) [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateStateChanged:) name:MCUpdateStateDidChangeNotification object:controller];
    [self refreshUpdatePage];
}
- (void)updateStateChanged:(__unused NSNotification *)notification { [self refreshUpdatePage]; }
- (void)refreshUpdatePage {
    self.automaticUpdatesCheckbox.enabled = self.updateController.available;
    self.automaticUpdatesCheckbox.state = self.updateController.automaticallyChecksForUpdates ? NSControlStateValueOn : NSControlStateValueOff;
    self.checkUpdatesButton.enabled = self.updateController.canCheckForUpdates;
    self.updateStatus.stringValue = self.updateController.statusText ?: @"更新服务尚未初始化。";
}
- (void)automaticUpdatesChanged:(NSButton *)sender {
    self.updateController.automaticallyChecksForUpdates = sender.state == NSControlStateValueOn;
    [self refreshUpdatePage];
}
- (void)checkUpdates:(id)sender { [self.updateController checkForUpdates:sender]; }
- (NSView *)updatesPage {
    NSView *page = [NSView new];
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"MoojiCutReleaseVersion"] ?: [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"开发版本";
    self.automaticUpdatesCheckbox = [NSButton checkboxWithTitle:@"自动检查更新" target:self action:@selector(automaticUpdatesChanged:)];
    self.checkUpdatesButton = [NSButton buttonWithTitle:@"检查更新…" target:self action:@selector(checkUpdates:)];
    self.checkUpdatesButton.bezelStyle = NSBezelStyleRounded;
    self.updateStatus = MCLabel(@"", 12, YES);
    NSStackView *stack = MCStack(@[MCHeading(@"软件更新"), MCLabel([@"当前版本 " stringByAppendingString:version], 13, NO), self.automaticUpdatesCheckbox,
        MCLabel(@"发现新版本时提醒你，由你确认下载与安装。", 12, YES), self.checkUpdatesButton, self.updateStatus], NSUserInterfaceLayoutOrientationVertical, 14);
    [self.updateStatus.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    [stack setCustomSpacing:6 afterView:self.automaticUpdatesCheckbox];
    MCPin(stack, page); [self refreshUpdatePage]; return page;
}
- (void)setAppearanceChoice:(NSString *)choice {
    NSArray *values = @[@"system", @"light", @"dark"];
    NSUInteger index = [values indexOfObject:choice]; if (index == NSNotFound) return;
    [self.defaults setObject:choice forKey:MCAppearanceKey];
    [self.appearancePopup selectItemAtIndex:(NSInteger)index];
    [MCPreferencesController applySavedAppearance:self.defaults];
}
- (void)toggleTechnicalDetails:(__unused id)sender {
    self.technicalDetails.hidden = !self.technicalDetails.hidden;
    self.disclosure.state = self.technicalDetails.hidden ? NSControlStateValueOff : NSControlStateValueOn;
    self.disclosure.accessibilityLabel = self.technicalDetails.hidden ? @"展开技术信息" : @"收起技术信息";
}
- (void)show { if (!self.window) [self buildWindow]; [self.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES]; }
- (void)selectPage:(NSString *)identifier {
    if (![@[@"general", @"shortcuts", @"about", @"updates"] containsObject:identifier]) return;
    [self cancelShortcutRecording];
    if (self.onShortcutRecordingChanged) self.onShortcutRecordingChanged(NO);
    [self.pages selectTabViewItemWithIdentifier:identifier]; self.window.toolbar.selectedItemIdentifier = identifier;
}
- (void)toolbarSelected:(NSToolbarItem *)sender { [self selectPage:sender.itemIdentifier]; }
- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(__unused NSToolbar *)toolbar { return @[@"general", @"shortcuts", @"about", @"updates"]; }
- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(__unused NSToolbar *)toolbar { return @[@"general", @"shortcuts", @"about", @"updates"]; }
- (NSArray<NSToolbarItemIdentifier> *)toolbarSelectableItemIdentifiers:(__unused NSToolbar *)toolbar { return @[@"general", @"shortcuts", @"about", @"updates"]; }
- (nullable NSToolbarItem *)toolbar:(__unused NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)identifier willBeInsertedIntoToolbar:(__unused BOOL)flag {
    if (![@[@"general", @"shortcuts", @"about", @"updates"] containsObject:identifier]) return nil;
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
    BOOL general = [identifier isEqualToString:@"general"];
    BOOL shortcuts = [identifier isEqualToString:@"shortcuts"];
    BOOL updates = [identifier isEqualToString:@"updates"];
    item.label = general ? @"通用" : shortcuts ? @"快捷键" : updates ? @"更新" : @"关于"; item.paletteLabel = item.label;
    item.image = [NSImage imageWithSystemSymbolName:general ? @"gearshape" : shortcuts ? @"keyboard" : updates ? @"arrow.triangle.2.circlepath" : @"info.circle" accessibilityDescription:item.label];
    item.target = self; item.action = @selector(toolbarSelected:); return item;
}
- (void)windowWillClose:(NSNotification *)notification {
    if (notification.object != self.window) return;
    [self cancelShortcutRecording];
    if (self.onShortcutRecordingChanged) self.onShortcutRecordingChanged(NO);
    // Preference toolbars keep AppKit view/validation state. Detach that state
    // before relinquishing the one settings window owned by this controller.
    self.window.toolbar.delegate = nil;
    for (NSToolbarItem *item in self.window.toolbar.items) item.target = nil;
    self.window.toolbar = nil;
    self.window.contentView = nil;
    self.window.delegate = nil; self.window = nil; self.pages = nil; self.appearancePopup = nil; self.technicalDetails = nil; self.disclosure = nil;
    self.shortcutRecorders = nil; self.shortcutClearButtons = nil; self.shortcutFeedback = nil; self.shortcutAvailability = nil;
    self.automaticUpdatesCheckbox = nil; self.checkUpdatesButton = nil; self.updateStatus = nil;
    if (self.onClose) self.onClose();
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end
