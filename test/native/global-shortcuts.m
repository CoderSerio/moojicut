#import <AppKit/AppKit.h>
#import "native/macos/shortcuts/MCGlobalShortcutManager.h"
#import "native/macos/preferences/MCShortcutStore.h"
#include "moonbit.h"

static BOOL sendHotKey(UInt32 signature, UInt32 action) {
  EventRef event = NULL;
  OSStatus status = CreateEvent(NULL, kEventClassKeyboard, kEventHotKeyPressed, GetCurrentEventTime(), kEventAttributeUserEvent, &event);
  if (status != noErr) return NO;
  EventHotKeyID identifier = {signature, action};
  status = SetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, sizeof(identifier), &identifier);
  if (status == noErr) status = SendEventToEventTarget(event, GetEventDispatcherTarget());
  ReleaseEvent(event);
  return status == noErr;
}
static BOOL sendAll(void) {
  return sendHotKey(MCCaptureHotKeySignature, MCCaptureHotKeyID) &&
    sendHotKey(MCCaptureHotKeySignature, MCRecordHotKeyID) && sendHotKey(MCCaptureHotKeySignature, MCStopHotKeyID);
}
static EventHotKeyRef reserve(UInt32 code, UInt32 identifier) {
  EventHotKeyRef reference = NULL;
  EventHotKeyID id = {0x4d4a5453, identifier};
  if (RegisterEventHotKey(code, cmdKey | controlKey | optionKey, id, GetApplicationEventTarget(), kEventHotKeyExclusive, &reference) != noErr)
    return NULL;
  return reference;
}
int main(void) {
    moonbit_init();
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    NSString *domain = [@"dev.moojicut.hotkey-test." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:domain];
    MCShortcutStore *store = [[MCShortcutStore alloc] initWithDefaults:defaults];
    NSEventModifierFlags flags = NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption;
    NSString *error = nil;
    NSArray<NSString *> *actions = @[@"capture", @"record", @"stop"];
    unsigned short codes[] = {64, 79, 80}; // Cmd+Ctrl+Option+F17/F18/F19; F20 is the collision/reload fixture.
    BOOL passed = YES;
    for (NSUInteger i = 0; i < 3; i++)
      passed = [store setShortcut:[MCShortcutStore shortcutWithKeyCode:codes[i] modifiers:flags] forAction:actions[i] error:&error] && passed;
    __block int captures = 0, records = 0, stops = 0;
    MCGlobalShortcutManager *manager = [[MCGlobalShortcutManager alloc] initWithDefaults:defaults onCapture:^{ captures++; }];
    manager.onRecord = ^{ records++; };
    manager.onStop = ^{ stops++; };
    [manager start];
    passed = manager.isRegistered && !manager.registrationError && passed;
    passed = sendAll() && captures == 1 && records == 1 && stops == 1 && passed;
    passed = !sendHotKey(0x12345678, MCCaptureHotKeyID) && !sendHotKey(MCCaptureHotKeySignature, 99) && passed;
    [manager suspend];
    passed = !sendAll() && !manager.isRegistered && captures == 1 && records == 1 && stops == 1 && passed;
    // Pause must actually unregister every combination, so a recorder can receive it.
    for (NSUInteger i = 0; i < 3; i++) {
      EventHotKeyRef probe = reserve(codes[i], (UInt32)i + 100);
      passed = probe != NULL && passed;
      if (probe) UnregisterEventHotKey(probe);
    }
    [manager resume];
    passed = manager.isRegistered && sendAll() && captures == 2 && records == 2 && stops == 2 && passed;
    [store setShortcut:nil forAction:@"capture" error:&error];
    passed = !sendHotKey(MCCaptureHotKeySignature, MCCaptureHotKeyID) && captures == 2 && manager.isRegistered && passed;
    passed = sendHotKey(MCCaptureHotKeySignature, MCRecordHotKeyID) && records == 3 && passed;
    passed = sendHotKey(MCCaptureHotKeySignature, MCStopHotKeyID) && stops == 3 && passed;
    EventHotKeyRef blocker = reserve(90, 200);
    passed = blocker != NULL && passed;
    [store setShortcut:[MCShortcutStore shortcutWithKeyCode:90 modifiers:flags] forAction:@"capture" error:&error];
    passed = manager.registrationError != nil && [manager.registrationError containsString:@"截图"] && passed;
    passed = !sendHotKey(MCCaptureHotKeySignature, MCCaptureHotKeyID) && captures == 2 && passed;
    passed = sendHotKey(MCCaptureHotKeySignature, MCRecordHotKeyID) && records == 4 && passed;
    passed = sendHotKey(MCCaptureHotKeySignature, MCStopHotKeyID) && stops == 4 && passed;
    if (blocker) UnregisterEventHotKey(blocker);
    [store setShortcut:[MCShortcutStore shortcutWithKeyCode:90 modifiers:flags] forAction:@"capture" error:&error];
    passed = !manager.registrationError && sendHotKey(MCCaptureHotKeySignature, MCCaptureHotKeyID) && captures == 3 && passed;
    [store setShortcut:[MCShortcutStore shortcutWithKeyCode:64 modifiers:flags] forAction:@"record" error:&error];
    passed = sendHotKey(MCCaptureHotKeySignature, MCRecordHotKeyID) && records == 5 && passed;
    [store setShortcut:nil forAction:@"record" error:&error];
    passed = !sendHotKey(MCCaptureHotKeySignature, MCRecordHotKeyID) && records == 5 && passed;
    passed = sendHotKey(MCCaptureHotKeySignature, MCStopHotKeyID) && stops == 5 && passed;
    for (NSString *action in actions) [store setShortcut:nil forAction:action error:&error];
    passed = !manager.isRegistered && !manager.registrationError && !sendAll() && passed;
    [manager invalidate];
    passed = !manager.isRegistered && passed;
    [defaults removePersistentDomainForName:domain];
    printf("Global capture/record/stop: dispatch, unknown events, pause releases all, resume, independent clear, config reload, occupied-key error and recovery: %s\n", passed ? "passed" : "FAILED");
    if (!passed) NSLog(@"Registration error: %@; counts: %d/%d/%d; setup error: %@",manager.registrationError,captures,records,stops,error);
    return passed ? 0 : 1;
  }
}
