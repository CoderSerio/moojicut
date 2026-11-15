#import <AppKit/AppKit.h>
#include "native/shared/shortcut_bindings.h"

// This adapter translates AppKit flags and property-list conventions only.
// Recovery, modifier requirements, conflict resolution and edits live in MoonBit.
static inline int32_t MCShortcutCoreFlags(NSEventModifierFlags flags) {
    return ((flags & NSEventModifierFlagControl) ? 1 : 0) |
        ((flags & NSEventModifierFlagOption) ? 2 : 0) |
        ((flags & NSEventModifierFlagShift) ? 4 : 0) |
        ((flags & NSEventModifierFlagCommand) ? 8 : 0);
}
static inline NSEventModifierFlags MCShortcutNativeFlags(int32_t flags) {
    return ((flags & 1) ? NSEventModifierFlagControl : 0) |
        ((flags & 2) ? NSEventModifierFlagOption : 0) |
        ((flags & 4) ? NSEventModifierFlagShift : 0) |
        ((flags & 8) ? NSEventModifierFlagCommand : 0);
}
static inline id MCShortcutCoreBinding(NSDictionary *binding) {
    if (!binding.count) return NSNull.null;
    return @{ @"keyCode":binding[@"keyCode"], @"keyLabel":binding[@"keyLabel"],
        @"modifiers":@(MCShortcutCoreFlags([binding[@"modifiers"] unsignedIntegerValue])) };
}
static inline NSDictionary *MCShortcutCoreMap(NSDictionary *values) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *action in values) result[action] = MCShortcutCoreBinding(values[action]);
    return result;
}
static inline NSDictionary *MCShortcutResolve(NSArray *order, NSArray *global,
        NSDictionary *defaults, NSDictionary *saved, NSString *action,
        NSDictionary *binding, NSDictionary *external, NSDictionary **error) {
    NSMutableDictionary *request = [@{@"order":order, @"global":global,
        @"defaults":MCShortcutCoreMap(defaults), @"saved":MCShortcutCoreMap(saved)} mutableCopy];
    if (action) request[@"command"] = @{@"action":action, @"binding":MCShortcutCoreBinding(binding)};
    if (external) request[@"external"] = MCShortcutCoreMap(external);
    NSData *data = [NSJSONSerialization dataWithJSONObject:request options:0 error:NULL];
    NSString *json = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    if (!json || json.length > 65536) return nil;
    moonbit_string_t input = moonbit_make_string_raw((int32_t)json.length);
    [json getCharacters:input range:NSMakeRange(0, json.length)];
    moonbit_string_t output = shortcut_bindings_resolve(input);
    moonbit_decref(input);
    if (!output) return nil;
    NSString *text = [[NSString alloc] initWithCharacters:output length:(NSUInteger)Moonbit_array_length(output)];
    moonbit_decref(output);
    NSDictionary *response = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
    if (![response[@"ok"] boolValue]) { if (error) *error = response[@"error"]; return nil; }
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *key in response[@"bindings"]) {
        id value = response[@"bindings"][key];
        result[key] = value == NSNull.null ? @{} : @{@"keyCode":value[@"keyCode"],
            @"keyLabel":value[@"keyLabel"], @"modifiers":@(MCShortcutNativeFlags([value[@"modifiers"] intValue]))};
    }
    return result;
}
