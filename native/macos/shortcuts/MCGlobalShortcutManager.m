#import "MCGlobalShortcutManager.h"
#import "../preferences/MCShortcutStore.h"
#import "../preferences/MCSystemShortcutCheck.h"

const UInt32 MCCaptureHotKeySignature = 0x4d4a4354;
const UInt32 MCCaptureHotKeyID = 1;
const UInt32 MCRecordHotKeyID = 2;
const UInt32 MCStopHotKeyID = 3;

@interface MCGlobalShortcutManager () {
    EventHotKeyRef _hotKeys[3];
}
@property NSUserDefaults *defaults;
@property (nonatomic, copy) void (^onCapture)(void);
@property (nonatomic, readwrite, copy, nullable) NSString *registrationError;
@property (nonatomic, assign) EventHandlerRef eventHandler;
@property BOOL started;
@property BOOL suspended;
- (OSStatus)handleEvent:(EventRef)event;
@end

static OSStatus MCHotKeyHandler(__unused EventHandlerCallRef next, EventRef event, void *context) {
    return [(__bridge MCGlobalShortcutManager *)context handleEvent:event];
}

@implementation MCGlobalShortcutManager
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults onCapture:(void (^)(void))onCapture {
    if ((self = [super init])) {
        _defaults = defaults;
        _onCapture = [onCapture copy];
    }
    return self;
}
- (BOOL)isRegistered { return _hotKeys[0] || _hotKeys[1] || _hotKeys[2]; }
- (void)publishError:(NSString *)error {
    self.registrationError = error;
    if (self.onStatusChanged) self.onStatusChanged(error);
}
- (void)unregisterShortcuts {
    for (NSUInteger index = 0; index < 3; index++) {
        if (_hotKeys[index]) { UnregisterEventHotKey(_hotKeys[index]); _hotKeys[index] = NULL; }
    }
}
- (void)registerShortcuts {
    NSAssert(NSThread.isMainThread, @"Global shortcuts must be managed on the main thread.");
    if (!self.started || self.suspended || !self.eventHandler) return;
    [self unregisterShortcuts];
    // Settings controllers own separate stores; reload the persisted snapshot.
    MCShortcutStore *store = [[MCShortcutStore alloc] initWithDefaults:self.defaults];
    NSArray<NSString *> *actions = @[@"capture", @"record", @"stop"];
    NSArray<NSString *> *names = @[@"截图", @"开始录屏", @"停止录屏"];
    NSMutableArray<NSString *> *errors = [NSMutableArray array];
    for (NSUInteger index = 0; index < actions.count; index++) {
        if ((index == 0 && !self.onCapture) || (index == 1 && !self.onRecord) || (index == 2 && !self.onStop)) continue;
        NSDictionary *shortcut = [store shortcutForAction:actions[index]];
        if (!shortcut) continue;
        unsigned short code = [shortcut[@"keyCode"] unsignedShortValue];
        NSEventModifierFlags flags = [shortcut[@"modifiers"] unsignedIntegerValue];
        NSString *systemConflict = MCSystemShortcutConflict(code, flags);
        if (systemConflict) {
            [errors addObject:[NSString stringWithFormat:@"%@快捷键未启用：%@", names[index], systemConflict]];
            continue;
        }
        UInt32 modifiers = 0;
        if (flags & NSEventModifierFlagCommand) modifiers |= cmdKey;
        if (flags & NSEventModifierFlagOption) modifiers |= optionKey;
        if (flags & NSEventModifierFlagControl) modifiers |= controlKey;
        if (flags & NSEventModifierFlagShift) modifiers |= shiftKey;
        EventHotKeyID identifier = {MCCaptureHotKeySignature, (UInt32)index + 1};
        EventHotKeyRef reference = NULL;
        OSStatus status = RegisterEventHotKey(code, modifiers, identifier, GetApplicationEventTarget(), kEventHotKeyExclusive, &reference);
        if (status != noErr) {
            if (reference) UnregisterEventHotKey(reference);
            [errors addObject:status == eventHotKeyExistsErr ?
                [NSString stringWithFormat:@"%@快捷键已被其他应用占用，请换一个组合。", names[index]] :
                [NSString stringWithFormat:@"%@快捷键注册失败（错误 %d），请重新设置。", names[index], (int)status]];
            continue;
        }
        _hotKeys[index] = reference;
    }
    [self publishError:errors.count ? [errors componentsJoinedByString:@"\n"] : nil];
}
- (void)shortcutsChanged:(__unused NSNotification *)notification {
    if (!NSThread.isMainThread) {
        __weak MCGlobalShortcutManager *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf registerShortcuts]; });
        return;
    }
    [self registerShortcuts];
}
- (void)start {
    NSAssert(NSThread.isMainThread, @"Global shortcuts must be managed on the main thread.");
    if (self.started) return;
    self.started = YES;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(shortcutsChanged:) name:MCShortcutsDidChangeNotification object:self.defaults];
    EventTypeSpec spec = {kEventClassKeyboard, kEventHotKeyPressed};
    EventHandlerRef handler = NULL;
    OSStatus status = InstallEventHandler(GetApplicationEventTarget(), MCHotKeyHandler, 1, &spec, (__bridge void *)self, &handler);
    if (status != noErr) {
        [self publishError:[NSString stringWithFormat:@"无法启动全局快捷键监听（错误 %d）。", (int)status]];
        return;
    }
    self.eventHandler = handler;
    [self registerShortcuts];
}
- (void)suspend {
    NSAssert(NSThread.isMainThread, @"Global shortcuts must be managed on the main thread.");
    self.suspended = YES;
    // Ignoring the callback is insufficient: Carbon would still consume the
    // key before the local shortcut recorder can read it.
    [self unregisterShortcuts];
}
- (void)resume {
    NSAssert(NSThread.isMainThread, @"Global shortcuts must be managed on the main thread.");
    if (!self.suspended) return;
    self.suspended = NO;
    [self registerShortcuts];
}
- (OSStatus)handleEvent:(EventRef)event {
    EventHotKeyID identifier = {0};
    OSStatus status = GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof(identifier), NULL, &identifier);
    if (status != noErr || identifier.signature != MCCaptureHotKeySignature || identifier.id < MCCaptureHotKeyID || identifier.id > MCStopHotKeyID)
        return eventNotHandledErr;
    if (!self.started || self.suspended || !_hotKeys[identifier.id - 1]) return eventNotHandledErr;
    if (identifier.id == MCCaptureHotKeyID && self.onCapture) self.onCapture();
    else if (identifier.id == MCRecordHotKeyID && self.onRecord) self.onRecord();
    else if (identifier.id == MCStopHotKeyID && self.onStop) self.onStop();
    return noErr;
}
- (void)invalidate {
    NSAssert(NSThread.isMainThread, @"Global shortcuts must be managed on the main thread.");
    [NSNotificationCenter.defaultCenter removeObserver:self name:MCShortcutsDidChangeNotification object:self.defaults];
    [self unregisterShortcuts];
    if (self.eventHandler) { RemoveEventHandler(self.eventHandler); self.eventHandler = NULL; }
    self.started = NO;
    self.suspended = NO;
}
- (void)dealloc {
    // The owner releases this object on the main thread after invalidate.
    [NSNotificationCenter.defaultCenter removeObserver:self];
    for (NSUInteger index = 0; index < 3; index++) if (_hotKeys[index]) UnregisterEventHotKey(_hotKeys[index]);
    if (_eventHandler) RemoveEventHandler(_eventHandler);
}
@end
