#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import "MCShortcutStore.h"
#import "MCSystemShortcutCheck.h"

int main(void) {
    @autoreleasepool {
        NSString *domain = [@"dev.moojicut.shortcuts.test." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:domain];
        @try {
            MCShortcutStore *store = [[MCShortcutStore alloc] initWithDefaults:defaults];
            NSDictionary *originalCapture = [store shortcutForAction:@"capture"];
            NSDictionary *originalRecord = [store shortcutForAction:@"record"];
            NSDictionary *originalStop = [store shortcutForAction:@"stop"];
            NSCAssert(originalCapture && originalRecord && originalStop, @"All capture actions have defaults");
            NSCAssert([MCShortcutStore displayStringForShortcut:originalCapture].length > 1, @"Readable shortcut symbols");

            // Select a chord not reserved by this Mac's actual system settings.
            NSDictionary *custom = nil;
            NSEventModifierFlags modifiers = NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption;
            for (unsigned short code = 0; code < 50; code++) {
                NSDictionary *candidate = [MCShortcutStore shortcutWithKeyCode:code modifiers:modifiers];
                if (candidate && !MCSystemShortcutConflict(code, modifiers)) { custom = candidate; break; }
            }
            NSCAssert(custom, @"A non-system chord is available for this test");
            NSString *error = nil;
            NSCAssert([store setShortcut:custom forAction:@"capture" error:&error], @"Save a valid chord: %@", error);
            [defaults synchronize];
            NSUserDefaults *reopenedDefaults = [[NSUserDefaults alloc] initWithSuiteName:domain];
            MCShortcutStore *reopened = [[MCShortcutStore alloc] initWithDefaults:reopenedDefaults];
            NSCAssert([[reopened shortcutForAction:@"capture"] isEqual:custom], @"A new preferences controller reads the saved chord");

            NSCAssert(![store setShortcut:custom forAction:@"record" error:&error] && error.length, @"Reject duplicate actions");
            NSCAssert([[store shortcutForAction:@"record"] isEqual:originalRecord], @"Conflict preserves the previous binding");
            NSDictionary *bare = @{ @"keyCode": @0, @"modifiers": @0 };
            NSCAssert(![store setShortcut:bare forAction:@"capture" error:&error], @"Do not intercept ordinary typing");
            NSDictionary *shiftOnly = @{ @"keyCode": @0, @"modifiers": @(NSEventModifierFlagShift) };
            NSCAssert(![store setShortcut:shiftOnly forAction:@"capture" error:&error], @"Shift alone is still ordinary typing");
            NSCAssert([[store shortcutForAction:@"capture"] isEqual:custom], @"Invalid input preserves the saved chord");

            CFArrayRef systemKeys = NULL;
            NSCAssert(CopySymbolicHotKeys(&systemKeys) == noErr && systemKeys, @"Read the real macOS hotkey configuration");
            NSArray *keys = CFBridgingRelease(systemKeys);
            NSUInteger checked = 0;
            for (NSDictionary *key in keys) {
                if (![key[(__bridge NSString *)kHISymbolicHotKeyEnabled] boolValue]) continue;
                NSUInteger carbon = [key[(__bridge NSString *)kHISymbolicHotKeyModifiers] unsignedIntegerValue];
                if (carbon & ~(cmdKey | shiftKey | optionKey | controlKey)) continue;
                NSUInteger cocoa = 0;
                if (carbon & cmdKey) cocoa |= NSEventModifierFlagCommand;
                if (carbon & shiftKey) cocoa |= NSEventModifierFlagShift;
                if (carbon & optionKey) cocoa |= NSEventModifierFlagOption;
                if (carbon & controlKey) cocoa |= NSEventModifierFlagControl;
                unsigned short code = [key[(__bridge NSString *)kHISymbolicHotKeyCode] unsignedShortValue];
                NSDictionary *candidate = [MCShortcutStore shortcutWithKeyCode:code modifiers:cocoa];
                if (!candidate) continue;
                NSCAssert(MCSystemShortcutConflict(code, cocoa).length, @"Detect an enabled system hotkey");
                NSCAssert(![store setShortcut:candidate forAction:@"capture" error:&error], @"Reject a system conflict");
                NSCAssert([[store shortcutForAction:@"capture"] isEqual:custom], @"System conflict preserves the previous binding");
                checked++;
            }
            printf("Checked %lu enabled system hotkeys.\n", (unsigned long)checked);

            NSCAssert([store setShortcut:nil forAction:@"capture" error:&error], @"Clear an action");
            [defaults synchronize];
            reopened = [[MCShortcutStore alloc] initWithDefaults:[[NSUserDefaults alloc] initWithSuiteName:domain]];
            NSCAssert([reopened shortcutForAction:@"capture"] == nil, @"Cleared shortcuts stay cleared after reopening");
            [store restoreDefaults];
            [defaults synchronize];
            reopened = [[MCShortcutStore alloc] initWithDefaults:[[NSUserDefaults alloc] initWithSuiteName:domain]];
            NSCAssert([[reopened shortcutForAction:@"capture"] isEqual:originalCapture] &&
                [[reopened shortcutForAction:@"record"] isEqual:originalRecord] &&
                [[reopened shortcutForAction:@"stop"] isEqual:originalStop], @"Restore all defaults");
            puts("PASS shortcut settings: persistence, duplicates, typing protection, clear and restore");
        } @finally {
            [defaults removePersistentDomainForName:domain];
            [defaults synchronize];
        }
    }
    return 0;
}
