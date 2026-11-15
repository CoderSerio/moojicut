#import "MCToolRegistryStore.h"
#include "native/shared/tool_registry.h"
#include <stdint.h>

NSNotificationName const MCToolRegistryDidChangeNotification = @"MCToolRegistryDidChangeNotification";
static NSString *const MCToolLayoutKey = @"builtinToolLayoutV1";

static NSError *MCToolError(NSString *message) {
    return [NSError errorWithDomain:@"dev.moojicut.tool-registry" code:1
        userInfo:@{NSLocalizedDescriptionKey:message}];
}
static NSString *MCToolJSON(id value, NSError **error) {
    // Defaults can contain property-list values such as NSDate/NSData that are
    // not JSON. Reject them before serialization can raise an exception.
    if (![NSJSONSerialization isValidJSONObject:value]) {
        if (error) *error = MCToolError(@"已保存的工具设置不是有效的布局数据。");
        return nil;
    }
    NSData *bytes = [NSJSONSerialization dataWithJSONObject:value options:0 error:error];
    return bytes ? [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding] : nil;
}
static NSDictionary *MCCallToolRegistry(moonbit_string_t (*function)(moonbit_string_t), NSString *json, NSError **error) {
    if (json.length > INT32_MAX) {
        if (error) *error = MCToolError(@"工具设置过大。");
        return nil;
    }
    moonbit_string_t input = moonbit_make_string_raw((int32_t)json.length);
    [json getCharacters:input range:NSMakeRange(0, json.length)];
    moonbit_string_t output = function(input);
    moonbit_decref(input);
    if (!output) { if (error) *error = MCToolError(@"无法读取工具设置。"); return nil; }
    NSString *text = [[NSString alloc] initWithCharacters:output length:(NSUInteger)Moonbit_array_length(output)];
    moonbit_decref(output);
    id value = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:error];
    if (![value isKindOfClass:NSDictionary.class]) {
        if (error) *error = MCToolError(@"工具设置返回了无效结果。");
        return nil;
    }
    if (![value[@"ok"] isKindOfClass:NSNumber.class] || ![value[@"ok"] boolValue]) {
        NSDictionary *detail = [value[@"error"] isKindOfClass:NSDictionary.class] ? value[@"error"] : nil;
        NSString *message = [detail[@"message"] isKindOfClass:NSString.class] ? detail[@"message"] : @"无法修改工具设置。";
        if (error) *error = MCToolError(message);
        return nil;
    }
    if (![value[@"layout"] isKindOfClass:NSDictionary.class] || ![value[@"groups"] isKindOfClass:NSDictionary.class]) {
        if (error) *error = MCToolError(@"工具设置缺少布局数据。");
        return nil;
    }
    // NSJSONSerialization's default containers are immutable, including nested
    // arrays. Neither UI consumers nor callbacks receive a mutable state alias.
    return value;
}

@interface MCToolRegistryStore ()
@property NSUserDefaults *defaults;
@property BOOL publishing;
@property (nonatomic, copy, readwrite) NSDictionary *snapshot;
@property (nonatomic, strong, readwrite, nullable) NSError *loadError;
@end

@implementation MCToolRegistryStore
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
    NSParameterAssert(NSThread.isMainThread);
    if ((self = [super init])) {
        _defaults = defaults;
        id saved = [defaults objectForKey:MCToolLayoutKey];
        NSError *error = nil;
        NSString *json = saved ? MCToolJSON(saved, &error) : @"";
        _snapshot = json ? MCCallToolRegistry(tool_registry_normalize, json, &error) : nil;
        if (!_snapshot) {
            _loadError = error ?: MCToolError(@"无法读取已保存的工具设置。");
            // Read-only recovery: never replace a corrupt saved value on launch.
            _snapshot = MCCallToolRegistry(tool_registry_normalize, @"", NULL);
        }
        if (!_snapshot) {
            _snapshot = @{@"layout":@{@"version":@1, @"groups":@{}}, @"groups":@{}};
        }
    }
    return self;
}
- (NSArray<NSDictionary *> *)toolsForGroup:(NSString *)group {
    NSAssert(NSThread.isMainThread, @"Tool snapshots are read on the main thread");
    id tools = self.snapshot[@"groups"][group];
    return [tools isKindOfClass:NSArray.class] ? tools : @[];
}
- (BOOL)performCommand:(NSDictionary *)command error:(NSError **)error {
    if (error) *error = nil;
    if (!NSThread.isMainThread || self.publishing) {
        if (error) *error = MCToolError(@"工具设置正在更新，请稍后重试。");
        return NO;
    }
    self.publishing = YES;
    @try {
        NSString *json = MCToolJSON(@{@"layout":self.snapshot[@"layout"], @"command":command}, error);
        NSDictionary *candidate = json ? MCCallToolRegistry(tool_registry_update, json, error) : nil;
        if (!candidate) return NO;
        if ([candidate[@"layout"] isEqual:self.snapshot[@"layout"]]) return YES;
        NSError *preflightError = nil;
        if (self.prepareChange && !self.prepareChange(candidate, &preflightError)) {
            if (error) *error = preflightError ?: MCToolError(@"请先完成当前编辑，再修改工具设置。");
            return NO;
        }
        [self.defaults setObject:candidate[@"layout"] forKey:MCToolLayoutKey];
        self.snapshot = candidate;
        self.loadError = nil;
        if (self.applyChange) self.applyChange(candidate);
        [NSNotificationCenter.defaultCenter postNotificationName:MCToolRegistryDidChangeNotification object:self];
        return YES;
    } @finally {
        self.publishing = NO;
    }
}
- (BOOL)setTool:(NSString *)identifier enabled:(BOOL)enabled error:(NSError **)error {
    return [self performCommand:@{@"type":@"enabled", @"id":identifier, @"enabled":@(enabled)} error:error];
}
- (BOOL)moveTool:(NSString *)identifier inGroup:(NSString *)group beforeTool:(NSString *)before error:(NSError **)error {
    return [self performCommand:@{@"type":@"move", @"id":identifier, @"group":group,
        @"beforeId":before ?: NSNull.null} error:error];
}
@end
