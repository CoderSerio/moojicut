#import "MCShortcutRecorder.h"
#import "MCShortcutStore.h"
#import "MCPinShortcutStore.h"

@interface MCShortcutRecorder ()
@property (nonatomic, readwrite, getter=isRecording) BOOL recording;
@property id eventMonitor;
@end

@implementation MCShortcutRecorder
- (instancetype)initWithFrame:(NSRect)frameRect {
    if ((self = [super initWithFrame:frameRect])) {
        self.bezelStyle = NSBezelStyleRounded;
        self.buttonType = NSButtonTypeMomentaryPushIn;
        self.font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightMedium];
        self.target = self; self.action = @selector(toggleRecording:);
        self.title = @"未设置";
        self.toolTip = @"点按后输入快捷键；Esc 取消，Delete 清除。";
        self.accessibilityHelp = @"点按后输入组合键。Escape 取消，Delete 清除，Tab 移到下一项。";
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowResigned:) name:NSWindowDidResignKeyNotification object:nil];
    }
    return self;
}
- (BOOL)acceptsFirstResponder { return YES; }
- (NSString *)accessibilityValue { return self.recording ? @"正在录入快捷键" : [MCShortcutStore displayStringForShortcut:self.shortcut]; }
- (void)setShortcut:(NSDictionary *)shortcut { _shortcut = [shortcut copy]; [self updateTitle]; }
- (void)updateTitle {
    self.title = self.recording ? @"按下快捷键…" : [MCShortcutStore displayStringForShortcut:self.shortcut];
    self.contentTintColor = self.recording ? NSColor.controlAccentColor : nil;
    NSAccessibilityPostNotification(self, NSAccessibilityValueChangedNotification);
}
- (void)toggleRecording:(__unused id)sender { if (self.recording) [self cancelRecording]; else [self beginRecording]; }
- (void)beginRecording {
    if (self.recording || !self.window) return;
    [self.window makeFirstResponder:self];
    self.recording = YES; [self updateTitle];
    if (self.onRecordingChanged) self.onRecordingChanged(YES);
    __weak MCShortcutRecorder *weakSelf = self;
    self.eventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown | NSEventMaskOtherMouseDown handler:^NSEvent *(NSEvent *event) {
        MCShortcutRecorder *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.recording) return event;
        if (event.window != strongSelf.window) { [strongSelf cancelRecording]; return event; }
        if (event.type == NSEventTypeKeyDown) { [strongSelf receiveKeyEvent:event]; return nil; }
        NSPoint point = [strongSelf convertPoint:event.locationInWindow fromView:nil];
        if (!NSPointInRect(point, strongSelf.bounds)) [strongSelf cancelRecording];
        return event;
    }];
}
- (void)cancelRecording {
    if (self.eventMonitor) { [NSEvent removeMonitor:self.eventMonitor]; self.eventMonitor = nil; }
    BOOL wasRecording = self.recording; self.recording = NO; [self updateTitle];
    if (wasRecording && self.onRecordingChanged) self.onRecordingChanged(NO);
}
- (void)receiveKeyEvent:(NSEvent *)event {
    if (!self.recording || event.isARepeat) return;
    if (event.keyCode == 53) { [self cancelRecording]; return; }
    if (event.keyCode == 48) {
        [self cancelRecording];
        if (event.modifierFlags & NSEventModifierFlagShift) [self.window selectPreviousKeyView:self];
        else [self.window selectNextKeyView:self];
        return;
    }
    if (event.keyCode == 51 || event.keyCode == 117) {
        if (!self.onChange || self.onChange(nil)) { self.shortcut = nil; [self cancelRecording]; }
        return;
    }
    NSDictionary *candidate = self.recordsPinShortcut ?
        [MCPinShortcutStore shortcutWithKeyCode:event.keyCode modifiers:event.modifierFlags] :
        [MCShortcutStore shortcutWithKeyCode:event.keyCode modifiers:event.modifierFlags];
    if (!candidate) {
        if (self.onError) self.onError(self.recordsPinShortcut ? @"请按一个普通按键，可同时使用修饰键。" : @"请使用 ⌘、⌥ 或 ⌃ 加一个按键，可同时按住 ⇧。");
        return;
    }
    NSMutableDictionary *value = [candidate mutableCopy];
    NSString *character = [event charactersByApplyingModifiers:0];
    if (!(self.recordsPinShortcut && ([candidate[@"keyCode"] unsignedShortValue] == 24 || [candidate[@"keyCode"] unsignedShortValue] == 27)) &&
        event.keyCode < 51 && event.keyCode != 36 && event.keyCode != 49 && character.length &&
        [character rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound) value[@"keyLabel"] = character.uppercaseString;
    if (!self.onChange || self.onChange(value)) { self.shortcut = value; [self cancelRecording]; }
}
- (void)keyDown:(NSEvent *)event {
    if (self.recording) [self receiveKeyEvent:event];
    else if (event.keyCode == 49 || event.keyCode == 36) [self beginRecording];
    else [super keyDown:event];
}
- (BOOL)resignFirstResponder { [self cancelRecording]; return [super resignFirstResponder]; }
- (void)viewWillMoveToWindow:(NSWindow *)window { if (window != self.window) [self cancelRecording]; [super viewWillMoveToWindow:window]; }
- (void)windowResigned:(NSNotification *)notification { if (notification.object == self.window) [self cancelRecording]; }
- (void)dealloc {
    if (_eventMonitor) [NSEvent removeMonitor:_eventMonitor];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}
@end
