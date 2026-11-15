#import "MCPinShortcutStore.h"
#import "MCShortcutStore.h"
#import "MCSystemShortcutCheck.h"
#import "MCShortcutPolicy.h"
#include <math.h>

NSNotificationName const MCPinShortcutsDidChangeNotification = @"MCPinShortcutsDidChangeNotification";
static NSString *const MCPinShortcutsKey = @"pinShortcuts.v1";
static NSEventModifierFlags const MCPinModifiers = NSEventModifierFlagCommand | NSEventModifierFlagOption |
    NSEventModifierFlagControl | NSEventModifierFlagShift;

static NSArray<NSString *> *MCPinActions(void) { return @[@"zoomIn", @"zoomOut", @"opacityUp", @"opacityDown", @"visibilityToggle", @"clickThroughToggle"]; }
static NSDictionary *MCPinDefaults(void) {
    return @{@"zoomIn":[MCPinShortcutStore shortcutWithKeyCode:24 modifiers:0],
        @"zoomOut":[MCPinShortcutStore shortcutWithKeyCode:27 modifiers:0],
        @"opacityUp":[MCPinShortcutStore shortcutWithKeyCode:24 modifiers:NSEventModifierFlagCommand],
        @"opacityDown":[MCPinShortcutStore shortcutWithKeyCode:27 modifiers:NSEventModifierFlagCommand],
        @"visibilityToggle":[MCPinShortcutStore shortcutWithKeyCode:4 modifiers:NSEventModifierFlagCommand | NSEventModifierFlagShift],
        @"clickThroughToggle":[MCPinShortcutStore shortcutWithKeyCode:35 modifiers:NSEventModifierFlagCommand | NSEventModifierFlagShift]};
}
static NSDictionary *MCPinNormalize(id value) {
    if (![value isKindOfClass:NSDictionary.class] || ![value[@"keyCode"] isKindOfClass:NSNumber.class] ||
        ![value[@"modifiers"] isKindOfClass:NSNumber.class]) return nil;
    double code = [value[@"keyCode"] doubleValue], flags = [value[@"modifiers"] doubleValue];
    if (!isfinite(code) || code < 0 || code > 126 || floor(code) != code ||
        !isfinite(flags) || flags < 0 || flags > UINT32_MAX || floor(flags) != flags ||
        CFGetTypeID((__bridge CFTypeRef)value[@"keyCode"]) == CFBooleanGetTypeID() ||
        CFGetTypeID((__bridge CFTypeRef)value[@"modifiers"]) == CFBooleanGetTypeID()) return nil;
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
    NSMutableDictionary *normalized = [NSMutableDictionary dictionary];
    NSDictionary *saved = [self.defaults dictionaryForKey:MCPinShortcutsKey];
    for (NSString *action in MCPinActions()) {
        id raw = saved[action];
        if ([raw isKindOfClass:NSDictionary.class] && [raw count] == 0) normalized[action] = @{};
        else { NSDictionary *value = MCPinNormalize(raw); if (value) normalized[action] = value; }
    }
    return MCShortcutResolve(MCPinActions(), @[@"visibilityToggle", @"clickThroughToggle"], MCPinDefaults(),
        normalized, nil, nil, nil, NULL) ?: @{};
}
- (NSDictionary *)shortcutForAction:(NSString *)action {
    NSDictionary *value = [self currentShortcuts][action];
    return value.count ? value : nil;
}
- (BOOL)setShortcut:(NSDictionary *)shortcut forAction:(NSString *)action error:(NSString **)error {
    if (error) *error = nil;
    NSDictionary *value = shortcut ? MCPinNormalize(shortcut) : nil;
    if (shortcut && !value) { if (error) *error = @"请按一个普通按键，可同时按住 ⌘、⌃、⌥ 或 ⇧。"; return NO; }
    MCShortcutStore *global = [[MCShortcutStore alloc] initWithDefaults:self.defaults];
    NSMutableDictionary *external = [NSMutableDictionary dictionary];
    for (NSString *other in @[@"capture", @"record", @"stop"]) {
        NSDictionary *binding = [global shortcutForAction:other]; if (binding) external[other] = binding;
    }
    NSDictionary *detail = nil;
    NSDictionary *values = MCShortcutResolve(MCPinActions(), @[@"visibilityToggle", @"clickThroughToggle"],
        MCPinDefaults(), [self currentShortcuts], action, value, external, &detail);
    if (!values) {
        NSString *code = detail[@"code"];
        NSDictionary *names = @{@"zoomIn":@"放大", @"zoomOut":@"缩小", @"opacityUp":@"提高不透明度", @"opacityDown":@"降低不透明度", @"visibilityToggle":@"隐藏/恢复", @"clickThroughToggle":@"鼠标穿透"};
        if (error) *error = [code isEqual:@"duplicate"] ?
            [NSString stringWithFormat:@"此按键已用于“%@”，请选择其他按键。", names[detail[@"message"]] ?: detail[@"message"]] :
            [code isEqual:@"external_duplicate"] ? @"此组合键已用于截图或录屏。" :
            [code isEqual:@"invalid_shortcut"] ? @"隐藏和鼠标穿透需要组合键，以便切换应用后恢复贴图。" : @"无法识别这个贴图操作。";
        return NO;
    }
    if (value && ([action isEqual:@"visibilityToggle"] || [action isEqual:@"clickThroughToggle"])) {
        NSString *conflict = MCSystemShortcutConflict([value[@"keyCode"] unsignedShortValue], [value[@"modifiers"] unsignedIntegerValue]);
        if (conflict) { if (error) *error = conflict; return NO; }
    }
    [self.defaults setObject:values forKey:MCPinShortcutsKey];
    [NSNotificationCenter.defaultCenter postNotificationName:MCPinShortcutsDidChangeNotification object:self.defaults];
    return YES;
}
- (void)restoreDefaults {
    [self restoreDefaultsWithError:NULL];
}
- (BOOL)restoreDefaultsWithError:(NSString **)error {
    if (error) *error = nil;
    NSDictionary *defaults = MCPinDefaults();
    MCShortcutStore *global = [[MCShortcutStore alloc] initWithDefaults:self.defaults];
    NSMutableDictionary *external = [NSMutableDictionary dictionary];
    for (NSString *action in @[@"capture", @"record", @"stop"]) {
        NSDictionary *value = [global shortcutForAction:action]; if (value) external[action] = value;
    }
    NSArray *globalActions = @[@"visibilityToggle", @"clickThroughToggle"];
    for (NSString *action in globalActions) {
        NSDictionary *value = defaults[action];
        if (!MCShortcutResolve(MCPinActions(), globalActions, defaults, defaults, action, value, external, NULL)) {
            if (error) *error = @"默认贴图组合与截图或录屏快捷键冲突，原设置已保留。"; return NO;
        }
        NSString *conflict = MCSystemShortcutConflict([value[@"keyCode"] unsignedShortValue], [value[@"modifiers"] unsignedIntegerValue]);
        if (conflict) { if (error) *error = conflict; return NO; }
    }
    [self.defaults setObject:defaults forKey:MCPinShortcutsKey];
    [NSNotificationCenter.defaultCenter postNotificationName:MCPinShortcutsDidChangeNotification object:self.defaults];
    return YES;
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
