#import "MCToolRegistryStore.h"
#import "plugins/feature/pin/macos/MCPinnedImageController.h"
#include "native/shared/tool_registry.h"
#include "native/shared/plugin_protocol.h"
#include <stdint.h>

NSNotificationName const MCToolRegistryDidChangeNotification = @"MCToolRegistryDidChangeNotification";
static NSString *const MCToolLayoutKey = @"builtinToolLayoutV1";
static NSString *const MCPinToolID = @"builtin.image.pin";

static BOOL MCSavedLayoutContainsPin(id saved) {
    if (![saved isKindOfClass:NSDictionary.class]) return NO;
    id groups = saved[@"groups"];
    if (![groups isKindOfClass:NSDictionary.class]) return NO;
    id entries = groups[@"screenshot"];
    if (![entries isKindOfClass:NSArray.class]) return NO;
    for (id entry in entries)
        if ([entry isKindOfClass:NSDictionary.class] && [entry[@"id"] isEqual:MCPinToolID]) return YES;
    return NO;
}

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
@property (nonatomic, copy, readwrite) NSArray<NSDictionary *> *pluginManifests;
@property (nonatomic, strong, readwrite, nullable) NSError *loadError;
@end

@implementation MCToolRegistryStore
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
    NSParameterAssert(NSThread.isMainThread);
    if ((self = [super init])) {
        _defaults = defaults;
        _pluginManifests = @[];
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
        if (!MCSavedLayoutContainsPin(saved) && [defaults objectForKey:MCPinFeatureEnabledDefaultsKey] &&
            ![defaults boolForKey:MCPinFeatureEnabledDefaultsKey]) {
            // Older releases stored the pin gate separately. Apply it only to
            // the in-memory normalized snapshot; construction never saves.
            NSString *migrationJSON = MCToolJSON(@{@"layout":_snapshot[@"layout"],
                @"command":@{@"type":@"enabled", @"id":MCPinToolID, @"enabled":@NO}}, &error);
            NSDictionary *migrated = migrationJSON ? MCCallToolRegistry(tool_registry_update, migrationJSON, &error) : nil;
            if (migrated) _snapshot = migrated;
            else if (!_loadError) _loadError = error;
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
        NSString *json = MCToolJSON(@{@"layout":self.snapshot[@"layout"], @"manifests":self.pluginManifests, @"command":command}, error);
        NSDictionary *candidate = json ? MCCallToolRegistry(tool_registry_resolve, json, error) : nil;
        if (!candidate) return NO;
        if ([candidate[@"layout"] isEqual:self.snapshot[@"layout"]]) return YES;
        NSError *preflightError = nil;
        if (self.prepareChange && !self.prepareChange(candidate, &preflightError)) {
            if (error) *error = preflightError ?: MCToolError(@"请先完成当前编辑，再修改工具设置。");
            return NO;
        }
        [self publishCandidate:candidate persist:YES];
        return YES;
    } @finally {
        self.publishing = NO;
    }
}
- (void)publishCandidate:(NSDictionary *)candidate persist:(BOOL)persist {
    if (persist) {
        [self.defaults setObject:candidate[@"layout"] forKey:MCToolLayoutKey];
        for (NSDictionary *tool in candidate[@"groups"][@"screenshot"]) {
            if ([tool[@"id"] isEqualToString:MCPinToolID]) {
                [self.defaults setBool:[tool[@"enabled"] boolValue] forKey:MCPinFeatureEnabledDefaultsKey];
                break;
            }
        }
        self.loadError = nil;
    }
    self.snapshot = candidate;
    if (self.applyChange) self.applyChange(candidate);
    [NSNotificationCenter.defaultCenter postNotificationName:MCToolRegistryDidChangeNotification object:self];
}
- (BOOL)replacePluginManifests:(NSArray<NSDictionary *> *)manifests commit:(BOOL (^)(NSError **))commit error:(NSError **)error {
    return [self replacePluginManifests:manifests commit:commit persistLayout:commit != nil error:error];
}
- (BOOL)replacePluginManifests:(NSArray<NSDictionary *> *)manifests commit:(BOOL (^)(NSError **))commit persistLayout:(BOOL)persistLayout error:(NSError **)error {
    if (error) *error = nil;
    if (!NSThread.isMainThread || self.publishing) {
        if (error) *error = MCToolError(@"工具设置正在更新，请稍后重试。");
        return NO;
    }
    self.publishing = YES;
    @try {
        NSString *json = MCToolJSON(@{@"layout":self.snapshot[@"layout"], @"manifests":manifests}, error);
        NSDictionary *candidate = json ? MCCallToolRegistry(tool_registry_resolve, json, error) : nil;
        if (!candidate) return NO;
        if (self.prepareChange && !self.prepareChange(candidate, error)) return NO;
        // The package store's atomic catalog rename is the commit point. No
        // editor or preference changes occur before this callback succeeds.
        if (commit && !commit(error)) return NO;
        self.pluginManifests = [manifests copy];
        [self publishCandidate:candidate persist:persistLayout];
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
