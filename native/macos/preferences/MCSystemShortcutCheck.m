#import "MCSystemShortcutCheck.h"
#import <Carbon/Carbon.h>

static BOOL MCFunctionKey(unsigned short keyCode) {
    switch (keyCode) {
        case kVK_F1: case kVK_F2: case kVK_F3: case kVK_F4: case kVK_F5:
        case kVK_F6: case kVK_F7: case kVK_F8: case kVK_F9: case kVK_F10:
        case kVK_F11: case kVK_F12: case kVK_F13: case kVK_F14: case kVK_F15:
        case kVK_F16: case kVK_F17: case kVK_F18: case kVK_F19: case kVK_F20:
            return YES;
        default: return NO;
    }
}

NSString * _Nullable MCSystemShortcutConflict(unsigned short keyCode, NSEventModifierFlags modifiers) {
    NSCAssert(NSThread.isMainThread, @"System shortcut checks must run on the main thread.");
    // CopySymbolicHotKeys uses Carbon modifiers, not NSEventModifierFlags.
    UInt32 expected = 0;
    if (modifiers & NSEventModifierFlagCommand) expected |= cmdKey;
    if (modifiers & NSEventModifierFlagShift) expected |= shiftKey;
    if (modifiers & NSEventModifierFlagOption) expected |= optionKey;
    if (modifiers & NSEventModifierFlagControl) expected |= controlKey;
    if (modifiers & NSEventModifierFlagFunction) expected |= kEventKeyModifierFnMask;
    UInt32 mask = cmdKey | shiftKey | optionKey | controlKey | kEventKeyModifierFnMask;
    // F-key events carry an implicit Fn bit. Do not strip Fn for ordinary
    // keys: Fn-Control-C and Control-C are different system shortcuts.
    if (MCFunctionKey(keyCode)) mask &= ~kEventKeyModifierFnMask;

    CFArrayRef hotkeys = NULL;
    OSStatus status = CopySymbolicHotKeys(&hotkeys);
    if (status != noErr || !hotkeys) {
        if (hotkeys) CFRelease(hotkeys);
        return nil;
    }
    BOOL conflict = NO;
    for (CFIndex index = 0; index < CFArrayGetCount(hotkeys); index++) {
        CFTypeRef item = CFArrayGetValueAtIndex(hotkeys, index);
        if (!item || CFGetTypeID(item) != CFDictionaryGetTypeID()) continue;
        CFDictionaryRef entry = (CFDictionaryRef)item;
        CFTypeRef enabled = CFDictionaryGetValue(entry, kHISymbolicHotKeyEnabled);
        CFTypeRef code = CFDictionaryGetValue(entry, kHISymbolicHotKeyCode);
        CFTypeRef flags = CFDictionaryGetValue(entry, kHISymbolicHotKeyModifiers);
        if (!enabled || CFGetTypeID(enabled) != CFBooleanGetTypeID() || !CFBooleanGetValue((CFBooleanRef)enabled) ||
            !code || CFGetTypeID(code) != CFNumberGetTypeID() || !flags || CFGetTypeID(flags) != CFNumberGetTypeID()) continue;
        SInt64 systemCode = 0, systemModifiers = 0;
        if (!CFNumberGetValue((CFNumberRef)code, kCFNumberSInt64Type, &systemCode) ||
            !CFNumberGetValue((CFNumberRef)flags, kCFNumberSInt64Type, &systemModifiers)) continue;
        // 65535 is an unbound symbolic shortcut, not a keyboard key.
        if (systemCode < 0 || systemCode >= 65535 || systemModifiers < 0) continue;
        if (systemCode == keyCode && (((UInt32)systemModifiers & mask) == (expected & mask))) {
            conflict = YES;
            break;
        }
    }
    CFRelease(hotkeys);
    return conflict ? @"此组合已用于 macOS 系统快捷键，请选择其他组合。" : nil;
}
