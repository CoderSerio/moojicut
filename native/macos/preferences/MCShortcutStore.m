#import "MCShortcutStore.h"
#import "MCPinShortcutStore.h"
#import "MCSystemShortcutCheck.h"
#import "MCShortcutPolicy.h"
#include <math.h>

NSNotificationName const MCShortcutsDidChangeNotification = @"MCShortcutsDidChangeNotification";
static NSString *const MCShortcutsKey = @"shortcuts.v1";
static NSEventModifierFlags const MCShortcutModifiers = NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagControl | NSEventModifierFlagShift;

static NSString *MCKeyLabel(unsigned short code) {
    // Stable fallback labels for macOS virtual key codes. The recorder supplies
    // the actual keyboard-layout character for printable keys.
    static NSDictionary<NSNumber *, NSString *> *labels;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        labels = @{
            @0:@"A", @1:@"S", @2:@"D", @3:@"F", @4:@"H", @5:@"G", @6:@"Z", @7:@"X", @8:@"C", @9:@"V", @11:@"B",
            @12:@"Q", @13:@"W", @14:@"E", @15:@"R", @16:@"Y", @17:@"T", @18:@"1", @19:@"2", @20:@"3", @21:@"4", @22:@"6", @23:@"5", @24:@"=", @25:@"9", @26:@"7", @27:@"−", @28:@"8", @29:@"0",
            @30:@"]", @31:@"O", @32:@"U", @33:@"[", @34:@"I", @35:@"P", @36:@"↩", @37:@"L", @38:@"J", @39:@"'", @40:@"K", @41:@";", @42:@"\\", @43:@",", @44:@"/", @45:@"N", @46:@"M", @47:@".", @49:@"空格", @50:@"`",
            @65:@"小数点", @67:@"小键盘 *", @69:@"小键盘 +", @75:@"小键盘 /", @76:@"⌤", @78:@"小键盘 −", @81:@"小键盘 =", @82:@"小键盘 0", @83:@"小键盘 1", @84:@"小键盘 2", @85:@"小键盘 3", @86:@"小键盘 4", @87:@"小键盘 5", @88:@"小键盘 6", @89:@"小键盘 7", @91:@"小键盘 8", @92:@"小键盘 9",
            @96:@"F5", @97:@"F6", @98:@"F7", @99:@"F3", @100:@"F8", @101:@"F9", @103:@"F11", @109:@"F10", @111:@"F12", @118:@"F4", @120:@"F2", @122:@"F1", @105:@"F13", @107:@"F14", @113:@"F15", @106:@"F16", @64:@"F17", @79:@"F18", @80:@"F19", @90:@"F20",
            @114:@"帮助", @115:@"↖", @116:@"⇞", @119:@"↘", @121:@"⇟", @123:@"←", @124:@"→", @125:@"↓", @126:@"↑",
            @10:@"§", @93:@"¥", @94:@"_", @95:@"小键盘 ,"
        };
    });
    return labels[@(code)];
}
static NSDictionary *MCDefaultShortcuts(void) {
    NSEventModifierFlags flags = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    return @{@"capture":[MCShortcutStore shortcutWithKeyCode:18 modifiers:flags],
        @"record":[MCShortcutStore shortcutWithKeyCode:19 modifiers:flags],
        @"stop":[MCShortcutStore shortcutWithKeyCode:7 modifiers:flags]};
}
static NSDictionary *MCNormalizeShortcut(NSDictionary *value) {
    if (![value isKindOfClass:NSDictionary.class] || ![value[@"keyCode"] isKindOfClass:NSNumber.class] || ![value[@"modifiers"] isKindOfClass:NSNumber.class]) return nil;
    double rawCode = [value[@"keyCode"] doubleValue], rawFlags = [value[@"modifiers"] doubleValue];
    if (!isfinite(rawCode) || rawCode < 0 || rawCode > 126 || floor(rawCode) != rawCode ||
        !isfinite(rawFlags) || rawFlags < 0 || rawFlags > UINT32_MAX || floor(rawFlags) != rawFlags ||
        CFGetTypeID((__bridge CFTypeRef)value[@"keyCode"]) == CFBooleanGetTypeID() ||
        CFGetTypeID((__bridge CFTypeRef)value[@"modifiers"]) == CFBooleanGetTypeID()) return nil;
    NSInteger code = (NSInteger)rawCode;
    NSDictionary *base = [MCShortcutStore shortcutWithKeyCode:(unsigned short)code modifiers:[value[@"modifiers"] unsignedIntegerValue]];
    if (!base) return nil;
    NSMutableDictionary *normalized = [base mutableCopy];
    NSString *label = value[@"keyLabel"];
    if ([label isKindOfClass:NSString.class] && label.length > 0 && label.length <= 16 && [label rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound) normalized[@"keyLabel"] = [label copy];
    return [normalized copy];
}

@interface MCShortcutStore ()
@property NSUserDefaults *defaults;
@property NSMutableDictionary<NSString *, NSDictionary *> *shortcuts;
@end

@implementation MCShortcutStore
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
    if ((self = [super init])) {
        _defaults = defaults;
        NSDictionary *platformDefaults = MCDefaultShortcuts();
        NSMutableDictionary *normalized = [NSMutableDictionary dictionary];
        NSDictionary *saved = [defaults dictionaryForKey:MCShortcutsKey];
        NSArray *actions = @[@"capture", @"record", @"stop"];
        for (NSString *action in actions) {
            id raw = saved[action];
            if ([raw isKindOfClass:NSDictionary.class] && [raw count] == 0) normalized[action] = @{};
            else { NSDictionary *value = MCNormalizeShortcut(raw); if (value) normalized[action] = value; }
        }
        _shortcuts = [MCShortcutResolve(actions, actions, platformDefaults, normalized, nil, nil, nil, NULL) mutableCopy];
        NSAssert(_shortcuts, @"The shared shortcut policy must accept platform defaults");
        if (!_shortcuts) _shortcuts = [NSMutableDictionary dictionary];
    }
    return self;
}
+ (NSDictionary *)shortcutWithKeyCode:(unsigned short)keyCode modifiers:(NSEventModifierFlags)modifiers {
    NSString *label = MCKeyLabel(keyCode);
    NSEventModifierFlags flags = modifiers & MCShortcutModifiers;
    if (!label || !shortcut_modifiers_allowed(MCShortcutCoreFlags(flags), 1)) return nil;
    return @{@"keyCode":@(keyCode), @"modifiers":@(flags), @"keyLabel":label};
}
- (NSDictionary *)shortcutForAction:(NSString *)action {
    NSDictionary *value = self.shortcuts[action];
    return value.count ? [value copy] : nil;
}
- (BOOL)setShortcut:(NSDictionary *)shortcut forAction:(NSString *)action error:(NSString **)error {
    if (error) *error = nil;
    NSDictionary *normalized = shortcut ? MCNormalizeShortcut(shortcut) : nil;
    if (shortcut && !normalized) { if (error) *error = @"请使用 ⌘、⌥ 或 ⌃ 加一个按键，可同时按住 ⇧。"; return NO; }
    NSArray *actions = @[@"capture", @"record", @"stop"];
    MCPinShortcutStore *pins = [[MCPinShortcutStore alloc] initWithDefaults:self.defaults];
    NSMutableDictionary *external = [NSMutableDictionary dictionary];
    for (NSString *other in @[@"visibilityToggle", @"clickThroughToggle"]) {
        NSDictionary *binding = [pins shortcutForAction:other]; if (binding) external[other] = binding;
    }
    NSDictionary *detail = nil;
    NSDictionary *resolved = MCShortcutResolve(actions, actions, MCDefaultShortcuts(), self.shortcuts,
        action, normalized, external, &detail);
    if (!resolved) {
        NSDictionary *names = @{@"capture":@"截图", @"record":@"开始录屏", @"stop":@"停止录屏"};
        if (error) *error = [detail[@"code"] isEqual:@"duplicate"] ?
            [NSString stringWithFormat:@"这个组合已用于“%@”，请选择其他按键。", names[detail[@"message"]] ?: detail[@"message"]] :
            [detail[@"code"] isEqual:@"external_duplicate"] ? @"这个组合已用于贴图隐藏或鼠标穿透，请选择其他按键。" : @"无法保存这个快捷键操作。";
        return NO;
    }
    if (normalized) {
        NSString *conflict = MCSystemShortcutConflict([normalized[@"keyCode"] unsignedShortValue], [normalized[@"modifiers"] unsignedIntegerValue]);
        if (conflict) { if (error) *error = conflict; return NO; }
    }
    self.shortcuts = [resolved mutableCopy];
    [self.defaults setObject:[self.shortcuts copy] forKey:MCShortcutsKey];
    [NSNotificationCenter.defaultCenter postNotificationName:MCShortcutsDidChangeNotification object:self.defaults];
    return YES;
}
- (void)restoreDefaults {
    [self restoreDefaultsWithError:NULL];
}
- (BOOL)restoreDefaultsWithError:(NSString **)error {
    if (error) *error = nil;
    NSDictionary *defaults = MCDefaultShortcuts();
    NSArray *actions = @[@"capture", @"record", @"stop"];
    MCPinShortcutStore *pins = [[MCPinShortcutStore alloc] initWithDefaults:self.defaults];
    NSMutableDictionary *external = [NSMutableDictionary dictionary];
    for (NSString *other in @[@"visibilityToggle", @"clickThroughToggle"]) {
        NSDictionary *value = [pins shortcutForAction:other]; if (value) external[other] = value;
    }
    for (NSString *action in actions) {
        NSDictionary *shortcut = defaults[action];
        if (!MCShortcutResolve(actions, actions, defaults, defaults, action, shortcut, external, NULL)) {
            if (error) *error = @"默认组合与贴图快捷键冲突，原设置已保留。"; return NO;
        }
        NSString *conflict = MCSystemShortcutConflict([shortcut[@"keyCode"] unsignedShortValue], [shortcut[@"modifiers"] unsignedIntegerValue]);
        if (conflict) { if (error) *error = [@"默认快捷键与系统设置冲突。" stringByAppendingString:conflict]; return NO; }
    }
    self.shortcuts = [defaults mutableCopy];
    [self.defaults setObject:[self.shortcuts copy] forKey:MCShortcutsKey];
    [NSNotificationCenter.defaultCenter postNotificationName:MCShortcutsDidChangeNotification object:self.defaults];
    return YES;
}
+ (NSString *)displayStringForShortcut:(NSDictionary *)shortcut {
    if (!shortcut.count) return @"未设置";
    NSUInteger flags = [shortcut[@"modifiers"] unsignedIntegerValue];
    NSMutableString *result = [NSMutableString string];
    if (flags & NSEventModifierFlagControl) [result appendString:@"⌃"];
    if (flags & NSEventModifierFlagOption) [result appendString:@"⌥"];
    if (flags & NSEventModifierFlagShift) [result appendString:@"⇧"];
    if (flags & NSEventModifierFlagCommand) [result appendString:@"⌘"];
    [result appendString:shortcut[@"keyLabel"] ?: MCKeyLabel([shortcut[@"keyCode"] unsignedShortValue]) ?: @"?"];
    return result;
}
@end
