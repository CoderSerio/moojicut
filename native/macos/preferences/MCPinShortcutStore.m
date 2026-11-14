#import "MCPinShortcutStore.h"
#import "MCShortcutStore.h"
#include <math.h>

NSNotificationName const MCPinShortcutsDidChangeNotification = @"MCPinShortcutsDidChangeNotification";
static NSString *const MCPinShortcutsKey = @"pinShortcuts.v1";
static NSEventModifierFlags const MCPinModifiers = NSEventModifierFlagCommand | NSEventModifierFlagOption |
    NSEventModifierFlagControl | NSEventModifierFlagShift;

static NSArray<NSString *> *MCPinActions(void) { return @[@"zoomIn", @"zoomOut", @"opacityUp", @"opacityDown"]; }
static NSDictionary *MCPinDefaults(void) {
    return @{@"zoomIn":[MCPinShortcutStore shortcutWithKeyCode:24 modifiers:0],
        @"zoomOut":[MCPinShortcutStore shortcutWithKeyCode:27 modifiers:0],
        @"opacityUp":[MCPinShortcutStore shortcutWithKeyCode:24 modifiers:NSEventModifierFlagCommand],
        @"opacityDown":[MCPinShortcutStore shortcutWithKeyCode:27 modifiers:NSEventModifierFlagCommand]};
}
static NSDictionary *MCPinNormalize(id value) {
    if (![value isKindOfClass:NSDictionary.class] || ![value[@"keyCode"] isKindOfClass:NSNumber.class] ||
        ![value[@"modifiers"] isKindOfClass:NSNumber.class]) return nil;
    double code = [value[@"keyCode"] doubleValue], flags = [value[@"modifiers"] doubleValue];
    if (!isfinite(code) || code < 0 || code > 126 || floor(code) != code ||
        !isfinite(flags) || flags < 0 || flags > UINT32_MAX || floor(flags) != flags) return nil;
    NSDictionary *base = [MCPinShortcutStore shortcutWithKeyCode:(unsigned short)code modifiers:(NSUInteger)flags];
    if (!base) return nil;
    NSMutableDictionary *result = [base mutableCopy];
    NSString *label = value[@"keyLabel"];
    if ([base[@"keyCode"] unsignedShortValue] != 24 && [base[@"keyCode"] unsignedShortValue] != 27 &&
        [label isKindOfClass:NSString.class] && label.length && label.length <= 16 &&
        [label rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound)
        result[@"keyLabel"] = label;
    return result;
}
static BOOL MCPinEqual(NSDictionary *a, NSDictionary *b) {
    return a && b && [a[@"keyCode"] isEqual:b[@"keyCode"]] && [a[@"modifiers"] isEqual:b[@"modifiers"]];
}

@interface MCPinShortcutStore ()
@property NSUserDefaults *defaults;
@end
@implementation MCPinShortcutStore
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
    if ((self = [super init])) _defaults = defaults;
    return self;
}
+ (NSDictionary *)shortcutWithKeyCode:(unsigned short)keyCode modifiers:(NSEventModifierFlags)modifiers {
    NSEventModifierFlags flags = modifiers & MCPinModifiers;
    // The main keyboard's = / Shift+= and the numeric keypad's + are one
    // zoom key. NumPad/CapsLock device flags do not change the shortcut.
    if (keyCode == 24 || keyCode == 69 || keyCode == 81) { keyCode = 24; flags &= ~NSEventModifierFlagShift; }
    else if (keyCode == 78) keyCode = 27;
    // Reuse the key label table, without the global store's modifier requirement.
    NSDictionary *key = [MCShortcutStore shortcutWithKeyCode:keyCode modifiers:flags | NSEventModifierFlagCommand];
    if (!key) return nil;
    return @{@"keyCode":@(keyCode), @"modifiers":@(flags),
        @"keyLabel":keyCode == 24 ? @"+" : keyCode == 27 ? @"−" : key[@"keyLabel"]};
}
- (NSDictionary *)currentShortcuts {
    NSMutableDictionary *values = [MCPinDefaults() mutableCopy];
    NSDictionary *saved = [self.defaults dictionaryForKey:MCPinShortcutsKey];
    NSMutableArray *seen = [NSMutableArray array];
    for (NSString *action in MCPinActions()) {
        id raw = saved[action];
        if ([raw isKindOfClass:NSDictionary.class] && [raw count] == 0) values[action] = @{};
        else if (MCPinNormalize(raw)) values[action] = MCPinNormalize(raw);
        NSDictionary *value = [values[action] count] ? values[action] : nil;
        for (NSDictionary *prior in seen) if (MCPinEqual(prior, value)) { values[action] = @{}; value = nil; break; }
        if (value) [seen addObject:value];
    }
    return values;
}
- (NSDictionary *)shortcutForAction:(NSString *)action {
    NSDictionary *value = [self currentShortcuts][action];
    return value.count ? value : nil;
}
- (BOOL)setShortcut:(NSDictionary *)shortcut forAction:(NSString *)action error:(NSString **)error {
    if (error) *error = nil;
    if (![MCPinActions() containsObject:action]) { if (error) *error = @"无法识别这个贴图操作。"; return NO; }
    NSDictionary *value = shortcut ? MCPinNormalize(shortcut) : nil;
    if (shortcut && !value) { if (error) *error = @"请按一个普通按键，可同时按住 ⌘、⌃、⌥ 或 ⇧。"; return NO; }
    NSMutableDictionary *values = [[self currentShortcuts] mutableCopy];
    if (value) for (NSString *other in MCPinActions()) {
        if (![other isEqual:action] && MCPinEqual(values[other], value)) {
            NSDictionary *names = @{@"zoomIn":@"放大", @"zoomOut":@"缩小", @"opacityUp":@"提高不透明度", @"opacityDown":@"降低不透明度"};
            if (error) *error = [NSString stringWithFormat:@"此按键已用于“%@”，请选择其他按键。", names[other]];
            return NO;
        }
    }
    values[action] = value ?: @{};
    [self.defaults setObject:values forKey:MCPinShortcutsKey];
    [NSNotificationCenter.defaultCenter postNotificationName:MCPinShortcutsDidChangeNotification object:self.defaults];
    return YES;
}
- (void)restoreDefaults {
    [self.defaults setObject:MCPinDefaults() forKey:MCPinShortcutsKey];
    [NSNotificationCenter.defaultCenter postNotificationName:MCPinShortcutsDidChangeNotification object:self.defaults];
}
- (NSString *)actionForKeyCode:(unsigned short)keyCode modifiers:(NSEventModifierFlags)modifiers {
    NSDictionary *key = [MCPinShortcutStore shortcutWithKeyCode:keyCode modifiers:modifiers];
    NSDictionary *values = [self currentShortcuts];
    for (NSString *action in MCPinActions()) if (MCPinEqual(values[action], key)) return action;
    return nil;
}
- (NSString *)actionForEvent:(NSEvent *)event {
    if (event.type != NSEventTypeKeyDown) return nil;
    return [self actionForKeyCode:event.keyCode modifiers:event.modifierFlags];
}
+ (NSString *)displayStringForShortcut:(NSDictionary *)shortcut {
    return [MCShortcutStore displayStringForShortcut:shortcut];
}
@end
