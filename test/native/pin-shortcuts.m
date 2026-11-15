#import <AppKit/AppKit.h>
#include "moonbit.h"
#import "native/macos/preferences/MCPinShortcutStore.h"
#import "native/macos/preferences/MCShortcutStore.h"
#import "native/macos/preferences/MCShortcutRecorder.h"
#import "native/macos/preferences/MCPreferencesController.h"

// The preferences fixture does not create or start an updater. Its notification
// name is the only updater symbol referenced by the otherwise real controller.
NSNotificationName const MCUpdateStateDidChangeNotification = @"MCUpdateStateDidChangeNotification";
@interface MCPreferencesController (MCPinSettingsTest)
- (void)buildWindow;
- (void)selectShortcutGroup:(NSSegmentedControl *)sender;
- (void)resetPinShortcuts:(id)sender;
@end

// Tests use an isolated defaults domain and a hidden recorder window. No
// global hotkeys are registered and no event is posted to another application.
static NSEvent *key(unsigned short code, NSEventModifierFlags flags) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags
        timestamp:0 windowNumber:0 context:nil characters:code == 24 ? @"+" : @"a"
        charactersIgnoringModifiers:code == 24 ? @"=" : @"a" isARepeat:NO keyCode:code];
}
#define CHECK(condition, message) do { \
    if (!(condition)) { fprintf(stderr, "FAIL pin shortcuts: %s\n", message); passed = NO; } \
} while (0)

int main(void) {
    @autoreleasepool {
        moonbit_init();
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        NSString *domain = [@"dev.moojicut.pin-shortcuts-test." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:domain];
        [defaults setObject:@{@"unchanged":@YES} forKey:@"shortcuts.v1"];
        NSDictionary *globalBefore = [defaults dictionaryForKey:@"shortcuts.v1"];
        MCPinShortcutStore *store = [[MCPinShortcutStore alloc] initWithDefaults:defaults];
        MCPinShortcutStore *otherWindow = [[MCPinShortcutStore alloc] initWithDefaults:defaults];
        BOOL passed = YES;
        __block NSUInteger notifications = 0;
        id observer = [NSNotificationCenter.defaultCenter addObserverForName:MCPinShortcutsDidChangeNotification
            object:defaults queue:nil usingBlock:^(__unused NSNotification *note) { notifications++; }];
        @try {
            CHECK([[store actionForEvent:key(24, 0)] isEqual:@"zoomIn"], "unmodified = enlarges a pin");
            CHECK([[store actionForEvent:key(24, NSEventModifierFlagShift)] isEqual:@"zoomIn"], "Shift+= also enlarges a pin");
            CHECK([[store actionForEvent:key(69, NSEventModifierFlagNumericPad)] isEqual:@"zoomIn"], "numeric keypad + enlarges a pin");
            CHECK([[store actionForEvent:key(81, NSEventModifierFlagNumericPad)] isEqual:@"zoomIn"], "numeric keypad = shares the + action");
            CHECK([[store actionForEvent:key(27, 0)] isEqual:@"zoomOut"] &&
                  [[store actionForEvent:key(78, NSEventModifierFlagNumericPad)] isEqual:@"zoomOut"], "both minus keys shrink a pin");
            CHECK([[store actionForEvent:key(24, NSEventModifierFlagCommand | NSEventModifierFlagShift)] isEqual:@"opacityUp"] &&
                  [[store actionForEvent:key(69, NSEventModifierFlagCommand | NSEventModifierFlagNumericPad)] isEqual:@"opacityUp"],
                  "Command+ changes opacity for both keyboard variants");
            CHECK([[store actionForEvent:key(27, NSEventModifierFlagCommand)] isEqual:@"opacityDown"], "Command− decreases opacity");
            CHECK([[store actionForEvent:key(4, NSEventModifierFlagCommand | NSEventModifierFlagShift)] isEqual:@"visibilityToggle"] &&
                  [[store actionForEvent:key(35, NSEventModifierFlagCommand | NSEventModifierFlagShift)] isEqual:@"clickThroughToggle"],
                  "recoverable hide and pass-through defaults are explicit combinations");
            CHECK(![store setShortcut:[MCPinShortcutStore shortcutWithKeyCode:4 modifiers:0] forAction:@"visibilityToggle" error:NULL],
                  "recovery actions reject unmodified global keys");
            MCShortcutStore *captureStore = [[MCShortcutStore alloc] initWithDefaults:defaults];
            CHECK(![store setShortcut:[captureStore shortcutForAction:@"capture"] forAction:@"clickThroughToggle" error:NULL],
                  "recovery actions reject capture shortcut conflicts");
            CHECK([store actionForEvent:key(0, 0)] == nil && [store actionForEvent:key(27, NSEventModifierFlagOption)] == nil,
                  "unbound keys and modifiers do not match");
            CHECK([MCShortcutStore shortcutWithKeyCode:24 modifiers:0] == nil,
                  "global shortcuts still require a command modifier");
            NSString *error = nil;
            NSDictionary *plusAlias = [MCPinShortcutStore shortcutWithKeyCode:69 modifiers:NSEventModifierFlagShift];
            CHECK(![store setShortcut:plusAlias forAction:@"zoomOut" error:&error] && error.length > 0 && notifications == 0,
                  "duplicate aliases are rejected without persisting or notifying");
            CHECK([[store actionForEvent:key(27, 0)] isEqual:@"zoomOut"], "failed updates preserve the old mapping");
            NSDictionary *custom = [MCPinShortcutStore shortcutWithKeyCode:0 modifiers:0];
            CHECK([store setShortcut:custom forAction:@"zoomIn" error:&error] && notifications == 1, "plain custom keys save and notify");
            CHECK([[otherWindow actionForEvent:key(0, 0)] isEqual:@"zoomIn"] && [otherWindow actionForEvent:key(24, 0)] == nil,
                  "existing windows see changed mappings immediately, including removal of old binding");
            CHECK([store setShortcut:nil forAction:@"zoomIn" error:&error] && [otherWindow shortcutForAction:@"zoomIn"] == nil,
                  "clear persists across store instances");
            CHECK([otherWindow actionForEvent:key(0, 0)] == nil, "cleared actions stop matching events");
            NSDictionary *controlPlus = [MCPinShortcutStore shortcutWithKeyCode:24 modifiers:NSEventModifierFlagControl];
            CHECK([store setShortcut:controlPlus forAction:@"opacityUp" error:&error], "Control can be configured explicitly");
            CHECK([[otherWindow actionForEvent:key(24, NSEventModifierFlagControl | NSEventModifierFlagShift)] isEqual:@"opacityUp"] &&
                  [otherWindow actionForEvent:key(24, NSEventModifierFlagCommand)] == nil, "custom Control replaces Command without hidden fallback");
            NSUInteger beforeInvalid = notifications;
            CHECK((![store setShortcut:@{@"keyCode":@24.5, @"modifiers":@0} forAction:@"zoomIn" error:&error] &&
                  ![store setShortcut:@{@"keyCode":@53, @"modifiers":@0} forAction:@"zoomIn" error:&error] &&
                  ![store setShortcut:custom forAction:@"unknown" error:&error] && notifications == beforeInvalid),
                  "invalid keys and action IDs do not mutate settings");
            [store restoreDefaults];
            CHECK([[otherWindow actionForEvent:key(24, 0)] isEqual:@"zoomIn"] &&
                  [[otherWindow actionForEvent:key(24, NSEventModifierFlagCommand)] isEqual:@"opacityUp"], "reset restores all default mappings");
            CHECK([[defaults dictionaryForKey:@"shortcuts.v1"] isEqual:globalBefore], "local changes never alter global shortcut preferences");
            CHECK([[MCPinShortcutStore displayStringForShortcut:[store shortcutForAction:@"opacityUp"]] isEqual:@"⌘+"],
                  "canonical plus is displayed consistently");

            // Persisted malformed values fall back safely; equivalent keys
            // must never dispatch two actions even in manually edited settings.
            [defaults setObject:@{@"zoomIn":@{@"keyCode":@24, @"modifiers":@0},
                @"zoomOut":@{@"keyCode":@69, @"modifiers":@(NSEventModifierFlagShift)},
                @"opacityDown":@{@"keyCode":@"bad", @"modifiers":@0}} forKey:@"pinShortcuts.v1"];
            CHECK([store shortcutForAction:@"zoomOut"] == nil && [[store actionForEvent:key(69, 0)] isEqual:@"zoomIn"],
                  "corrupt duplicate mappings are disabled deterministically");
            CHECK([[store actionForEvent:key(27, NSEventModifierFlagCommand)] isEqual:@"opacityDown"], "malformed values recover defaults");
            [store restoreDefaults];

            NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 120)
                styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
            window.releasedWhenClosed = NO;
            MCShortcutRecorder *recorder = [[MCShortcutRecorder alloc] initWithFrame:NSMakeRect(20, 20, 320, 28)];
            [window.contentView addSubview:recorder];
            __block NSDictionary *recorded = nil;
            __block NSUInteger errors = 0;
            recorder.onChange = ^BOOL(NSDictionary *shortcut) { recorded = shortcut; return YES; };
            recorder.onError = ^(__unused NSString *message) { errors++; };
            [recorder beginRecording]; [recorder receiveKeyEvent:key(24, 0)];
            CHECK(recorded == nil && recorder.isRecording && errors == 1, "global recorder continues to reject plain keys");
            [recorder cancelRecording];
            recorder.recordsPinShortcut = YES;
            [recorder beginRecording]; [recorder receiveKeyEvent:key(24, NSEventModifierFlagShift)];
            CHECK(!recorder.isRecording && [recorded[@"keyCode"] integerValue] == 24 &&
                  [recorded[@"modifiers"] unsignedIntegerValue] == 0 && [recorded[@"keyLabel"] isEqual:@"+"],
                  "local recorder accepts and normalizes Shift+ without changing the global recorder behavior");
            [recorder beginRecording]; [recorder receiveKeyEvent:key(51, 0)];
            CHECK(recorded == nil && recorder.shortcut == nil && !recorder.isRecording, "Delete clears a recorded local shortcut");
            [recorder beginRecording]; [recorder receiveKeyEvent:key(53, 0)];
            CHECK(!recorder.isRecording && !window.visible, "Escape exits recording without displaying a window");
            [window close];

            MCPreferencesController *preferences = [[MCPreferencesController alloc] initWithDefaults:defaults coreVersion:@"test" diagnostics:@{}];
            CHECK(preferences.pinningEnabled, "pin feature is enabled before the first explicit preference");
            __block NSUInteger capabilityChanges = 0;
            preferences.onPinningEnabledChanged = ^(BOOL enabled) { (void)enabled; capabilityChanges++; };
            [preferences setPinningEnabled:NO];
            MCPreferencesController *reopened = [[MCPreferencesController alloc] initWithDefaults:defaults coreVersion:@"test" diagnostics:@{}];
            CHECK(!reopened.pinningEnabled && capabilityChanges == 1, "pin feature preference persists and dispatches one host lifecycle change");
            [preferences setPinningEnabled:YES];
            __block BOOL recordingSettings = NO;
            preferences.onShortcutRecordingChanged = ^(BOOL active) { recordingSettings = active; };
            [preferences buildWindow]; [preferences selectPage:@"shortcuts"];
            NSSegmentedControl *groupSelector = [NSSegmentedControl segmentedControlWithLabels:@[@"global", @"pin"]
                trackingMode:NSSegmentSwitchTrackingSelectOne target:nil action:NULL];
            groupSelector.selectedSegment = 1; [preferences selectShortcutGroup:groupSelector];
            NSTabView *groups = [preferences valueForKey:@"shortcutGroups"];
            [preferences.window.contentView layoutSubtreeIfNeeded];
            CHECK([groups.selectedTabViewItem.identifier isEqual:@"pin"] &&
                  groups.selectedTabViewItem.view.fittingSize.height <= groups.bounds.size.height && !preferences.window.visible,
                  "pin settings have a separate group and fit the hidden preferences window");
            NSDictionary<NSString *, MCShortcutRecorder *> *pinRecorders = [preferences valueForKey:@"pinShortcutRecorders"];
            CHECK(pinRecorders.count == 6, "all six pin actions are configurable");
            MCShortcutRecorder *zoomRecorder = pinRecorders[@"zoomIn"];
            [zoomRecorder beginRecording]; [zoomRecorder receiveKeyEvent:key(0, 0)];
            CHECK([[otherWindow actionForEvent:key(0, 0)] isEqual:@"zoomIn"] && !recordingSettings,
                  "recording in preferences saves a local key and ends the recording state");
            MCShortcutRecorder *smallerRecorder = pinRecorders[@"zoomOut"];
            [smallerRecorder beginRecording]; [smallerRecorder receiveKeyEvent:key(0, 0)];
            CHECK(smallerRecorder.isRecording && recordingSettings &&
                  [[otherWindow actionForEvent:key(27, 0)] isEqual:@"zoomOut"],
                  "settings reject a conflict and preserve the previous binding");
            [pinRecorders[@"opacityUp"] beginRecording];
            CHECK(!smallerRecorder.isRecording && pinRecorders[@"opacityUp"].isRecording && recordingSettings,
                  "only one local shortcut records at a time");
            groupSelector.selectedSegment = 0; [preferences selectShortcutGroup:groupSelector];
            CHECK(!recordingSettings && !pinRecorders[@"opacityUp"].isRecording,
                  "leaving pin settings stops its active recorder");
            NSDictionary<NSString *, MCShortcutRecorder *> *globalRecorders = [preferences valueForKey:@"shortcutRecorders"];
            [globalRecorders[@"capture"] beginRecording];
            CHECK(globalRecorders[@"capture"].isRecording && recordingSettings,
                  "global shortcut recording remains available in its own group");
            groupSelector.selectedSegment = 1;
            [preferences selectShortcutGroup:groupSelector];
            CHECK(!recordingSettings && !globalRecorders[@"capture"].isRecording,
                  "switching settings groups stops shortcut recording");
            [preferences resetPinShortcuts:nil];
            CHECK([[otherWindow actionForEvent:key(24, 0)] isEqual:@"zoomIn"] &&
                  [[defaults dictionaryForKey:@"shortcuts.v1"] isEqual:globalBefore],
                  "the pin settings reset restores local defaults without touching global mappings");
            [preferences.window close];
        } @finally {
            [NSNotificationCenter.defaultCenter removeObserver:observer];
            [defaults removePersistentDomainForName:domain];
        }
        puts(passed ? "PASS pin shortcuts: local defaults, key aliases, remapping, conflicts, live reload, reset and recorder isolation"
                    : "FAIL pin shortcuts");
        return passed ? 0 : 1;
    }
}
