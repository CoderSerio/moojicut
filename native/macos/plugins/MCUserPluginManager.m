#import "MCUserPluginManager.h"
#import "MCPluginPackageStore.h"
#import "MCPluginWorker.h"
#import "MCPluginResultController.h"
#import "native/macos/preferences/MCToolRegistryStore.h"
#include "bindings/c/plugin_protocol.h"
#include "bindings/c/feature_runtime.h"

NSNotificationName const MCUserPluginsDidChangeNotification = @"MCUserPluginsDidChangeNotification";
static NSError *MCPluginError(NSString *message) {
    return [NSError errorWithDomain:@"dev.moojicut.user-plugins" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
static NSDictionary *MCProtocol(moonbit_string_t (*function)(moonbit_string_t), NSString *json, NSError **error) {
    NSCAssert(NSThread.isMainThread, @"MoonBit plugin policy runs on the main thread");
    if (!json || json.length > 600000) { if (error) *error = MCPluginError(@"插件协议数据过大或不是 UTF-8。"); return nil; }
    moonbit_string_t input = moonbit_make_string_raw((int32_t)json.length);
    [json getCharacters:input range:NSMakeRange(0,json.length)];
    moonbit_string_t output = function(input); moonbit_decref(input);
    if (!output) { if (error) *error = MCPluginError(@"无法校验插件数据。"); return nil; }
    NSString *text = [[NSString alloc] initWithCharacters:output length:(NSUInteger)Moonbit_array_length(output)]; moonbit_decref(output);
    id value = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:error];
    if (![value isKindOfClass:NSDictionary.class] || ![value[@"ok"] boolValue]) {
        NSString *message = [value isKindOfClass:NSDictionary.class] ? value[@"error"][@"message"] : nil;
        if (error) *error = MCPluginError(message ?: @"插件协议校验失败。"); return nil;
    }
    return value;
}
static NSString *MCJSON(id object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}
static NSDictionary *MCCheckedOutput(NSData *output, NSString *invocationID, NSError **error) {
    if (output.length > 262144) { if (error) *error = MCPluginError(@"插件结果超过 256 KiB。"); return nil; }
    NSString *raw = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding];
    if (!raw) { if (error) *error = MCPluginError(@"插件结果不是 UTF-8 文本。"); return nil; }
    // Keep the original JSON bytes: decoding in Foundation first would erase
    // duplicate keys before the MoonBit protocol checker sees them.
    NSString *envelope = MCJSON(@{@"invocationId":invocationID});
    NSString *prefix = [envelope stringByReplacingCharactersInRange:NSMakeRange(envelope.length-1,1) withString:@",\"output\":"];
    return MCProtocol(plugin_output_validate, [[prefix stringByAppendingString:raw] stringByAppendingString:@"}"], error)[@"result"];
}
static NSImage *MCPluginIcon(NSData *data, NSError **error) {
    if (!data) return nil;
    const unsigned char *b = data.bytes;
    const unsigned char magic[] = {137,80,78,71,13,10,26,10};
    if (data.length < 24 || memcmp(b,magic,8) || memcmp(b+12,"IHDR",4)) {
        if (error) *error = MCPluginError(@"插件图标必须是 PNG。"); return nil;
    }
    uint32_t width = ((uint32_t)b[16]<<24)|((uint32_t)b[17]<<16)|((uint32_t)b[18]<<8)|b[19];
    uint32_t height = ((uint32_t)b[20]<<24)|((uint32_t)b[21]<<16)|((uint32_t)b[22]<<8)|b[23];
    if (!width || !height || width > 512 || height > 512) { if (error) *error = MCPluginError(@"插件图标尺寸须为 1–512 像素。"); return nil; }
    NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:data];
    if (!bitmap || bitmap.pixelsWide != width || bitmap.pixelsHigh != height) { if (error) *error = MCPluginError(@"插件图标无法读取。"); return nil; }
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(20,20)]; [image addRepresentation:bitmap]; return image;
}
@interface MCUserPluginCall : NSObject
@property NSString *pluginID;
@property NSString *toolID;
@property NSString *digest;
@property NSString *owner;
@property MCPluginWorker *worker;
@property BOOL cancelled;
@end
@implementation MCUserPluginCall
@end
@interface MCUserPluginManager ()
@property MCToolRegistryStore *registry;
@property MCPluginPackageStore *packages;
@property NSURL *workerURL;
@property dispatch_queue_t files;
@property NSMutableDictionary<NSString *,NSDictionary *> *records;
// Disk ownership is separate from successfully loaded runtime records. A bad
// package must remain visible to the uninstall UI without trusting its metadata.
@property (copy) NSDictionary<NSString *,NSString *> *lastCatalog;
@property NSMutableDictionary<NSString *,NSNumber *> *states;
@property NSMutableArray<MCUserPluginCall *> *calls;
@property NSMutableArray<NSDictionary *> *results;
// A successful invocation grants one presentation of that exact result object.
// Weak keys do not retain outputs a caller discards without opening a window.
@property NSMapTable<NSDictionary *, NSDictionary *> *resultLeases;
@property MCPluginWorker *probe;
@property (nonatomic, readwrite, getter=isBusy) BOOL busy;
@property (nonatomic, copy, readwrite) NSString *statusMessage;
@property BOOL stopping;
@property (copy) void (^stopped)(void);
@end
@implementation MCUserPluginManager
- (instancetype)initWithRegistry:(MCToolRegistryStore *)registry packages:(MCPluginPackageStore *)packages workerURL:(NSURL *)workerURL {
    if ((self = [super init])) {
        _registry=registry; _packages=packages; _workerURL=workerURL; _files=dispatch_queue_create("dev.moojicut.plugin-files", DISPATCH_QUEUE_SERIAL);
        _records=[NSMutableDictionary dictionary]; _lastCatalog=@{}; _states=[NSMutableDictionary dictionary]; _calls=[NSMutableArray array]; _results=[NSMutableArray array]; _statusMessage=@"";
        _resultLeases=[NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality valueOptions:NSPointerFunctionsStrongMemory];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(registryChanged:) name:MCToolRegistryDidChangeNotification object:registry];
    }
    return self;
}
- (NSArray<NSString *> *)installedPluginIDs { return [self.lastCatalog.allKeys sortedArrayUsingSelector:@selector(compare:)]; }
- (NSArray *)manifestsForRecords:(NSDictionary *)records {
    NSMutableArray *manifests=[NSMutableArray array];
    for (NSString *key in [records.allKeys sortedArrayUsingSelector:@selector(compare:)]) [manifests addObject:records[key][@"manifest"]];
    return manifests;
}
- (void)changed { [NSNotificationCenter.defaultCenter postNotificationName:MCUserPluginsDidChangeNotification object:self]; }
- (void)finishOperation:(NSError *)error message:(NSString *)message completion:(void (^)(NSError *))completion {
    self.busy=NO; self.statusMessage=error ? error.localizedDescription : message; [self changed]; completion(error); [self finishShutdownIfReady];
}
- (BOOL)beginOperation:(void (^)(NSError *))completion {
    if (self.busy || self.stopping) { completion(MCPluginError(@"插件操作正在进行，请稍后重试。")); return NO; }
    self.busy=YES; self.statusMessage=@"正在检查插件…"; [self changed]; return YES;
}
- (NSDictionary *)recordForCandidate:(MCPluginPackageCandidate *)candidate error:(NSError **)error {
    NSString *raw=[[NSString alloc] initWithData:candidate.manifestData encoding:NSUTF8StringEncoding];
    NSDictionary *manifest=MCProtocol(plugin_manifest_validate,raw,error)[@"manifest"];
    if (!manifest) return nil;
    NSImage *icon=MCPluginIcon(candidate.iconData,error);
    if (candidate.iconData && !icon) return nil;
    NSMutableDictionary *record=[@{@"manifest":manifest,@"package":candidate} mutableCopy];
    if (icon) record[@"icon"]=icon; return record;
}
- (NSDictionary *)requestForManifest:(NSDictionary *)manifest tool:(NSString *)tool invocation:(NSString *)invocation capture:(NSDictionary *)capture error:(NSError **)error {
    return MCProtocol(plugin_request_prepare, MCJSON(@{@"manifest":manifest,@"toolId":tool,@"invocationId":invocation,@"capture":capture}),error)[@"request"];
}
- (void)probeRecord:(NSDictionary *)record index:(NSUInteger)index completion:(void (^)(NSError *))completion {
    if (self.stopping) { completion(MCPluginError(@"插件操作已取消。")); return; }
    NSDictionary *manifest=record[@"manifest"]; NSArray *tools=manifest[@"tools"];
    if (index == tools.count) { completion(nil); return; }
    NSString *identifier=[NSString stringWithFormat:@"user.%@/%@",manifest[@"pluginId"],tools[index][@"toolId"]];
    NSString *invocation=NSUUID.UUID.UUIDString; NSError *error=nil;
    NSDictionary *request=[self requestForManifest:manifest tool:identifier invocation:invocation
        capture:@{@"width":@1440,@"height":@900,@"format":@"png",@"revision":@0} error:&error];
    if (!request) { completion(error ?: MCPluginError(@"插件试运行请求无效。")); return; }
    self.statusMessage=[NSString stringWithFormat:@"正在验证 %@（%lu/%lu）…",manifest[@"name"],(unsigned long)index+1,(unsigned long)tools.count]; [self changed];
    // Notification observers may synchronously initiate shutdown.
    if (self.stopping) { completion(MCPluginError(@"插件操作已取消。")); return; }
    MCPluginPackageCandidate *package=record[@"package"];
    self.probe=[MCPluginWorker startWithExecutableURL:self.workerURL wasmData:package.wasmData inputData:[MCJSON(request) dataUsingEncoding:NSUTF8StringEncoding]
        limits:MCPluginWorkerDefaultLimits() completion:^(NSData *output,NSError *failure) {
            self.probe=nil; NSError *checked=failure;
            if (!checked && !MCCheckedOutput(output,invocation,&checked)) { if (!checked) checked=MCPluginError(@"插件试运行未返回有效文本。"); }
            if (checked) completion(checked); else [self probeRecord:record index:index+1 completion:completion];
        }];
}
- (void)loadRecords:(NSArray *)items index:(NSUInteger)index accepted:(NSMutableDictionary *)accepted errors:(NSMutableArray *)errors completion:(void (^)(NSError *))completion {
    if (index==items.count || self.stopping) {
        NSError *error=nil;
        if (self.stopping) error=MCPluginError(@"插件加载已取消。");
        else {
            BOOL published=[self.registry replacePluginManifests:[self manifestsForRecords:accepted] commit:^BOOL(NSError **publicationError) {
                if (self.stopping) { if (publicationError) *publicationError=MCPluginError(@"插件加载已取消。"); return NO; }
                self.records=accepted; return YES;
            } persistLayout:NO error:&error];
            if (published) [self applyToolConfiguration:self.registry.snapshot];
            else if (!error) error=MCPluginError(@"当前编辑状态不允许加载插件，请完成编辑后重试。");
        }
        if (!error && errors.count) error=MCPluginError([@"部分插件无法加载：" stringByAppendingString:[errors componentsJoinedByString:@"；"]]);
        [self finishOperation:error message:@"插件已加载。" completion:completion]; return;
    }
    NSDictionary *item=items[index]; NSError *error=item[@"error"];
    NSDictionary *record=error ? nil : [self recordForCandidate:item[@"package"] error:&error];
    if (record && ![record[@"manifest"][@"pluginId"] isEqual:item[@"id"]]) { error=MCPluginError(@"目录与清单 ID 不一致。"); record=nil; }
    if (!record) {
        [errors addObject:[NSString stringWithFormat:@"%@：%@",item[@"id"],error.localizedDescription ?: @"包不可读"]];
        [self loadRecords:items index:index+1 accepted:accepted errors:errors completion:completion]; return;
    }
    // Startup restores only previously committed, hash-checked payloads and
    // validated metadata. Never execute a disabled plugin as a side effect of
    // launching the app. Import/update probe every tool before their commit;
    // each user invocation still checks the runtime and validates its output.
    accepted[item[@"id"]]=record;
    [self loadRecords:items index:index+1 accepted:accepted errors:errors completion:completion];
}
- (void)loadInstalledPluginsWithCompletion:(void (^)(NSError *))completion {
    if (![self beginOperation:completion]) return;
    dispatch_async(self.files, ^{
        NSError *error=nil; NSDictionary *catalog=[self.packages catalogWithError:&error]; NSMutableArray *items=[NSMutableArray array];
        if (!catalog && !error) error=MCPluginError(@"无法读取已安装插件索引。");
        if (catalog.count>16) error=MCPluginError(@"当前版本最多安装 16 个插件。");
        if (!error) for (NSString *key in [catalog.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            NSError *readError=nil; MCPluginPackageCandidate *package=[self.packages packageForPluginID:key error:&readError];
            [items addObject:package ? @{@"id":key,@"package":package} : @{@"id":key,@"error":readError ?: MCPluginError(@"包不可读")}];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (catalog) self.lastCatalog=catalog;
            if (error) [self finishOperation:error message:@"" completion:completion];
            else [self loadRecords:items index:0 accepted:[NSMutableDictionary dictionary] errors:[NSMutableArray array] completion:completion];
        });
    });
}
- (void)importZIPAtURL:(NSURL *)url completion:(void (^)(NSError *))completion {
    if (![self beginOperation:completion]) return;
    dispatch_async(self.files, ^{
        NSError *error=nil; MCPluginPackageCandidate *candidate=[self.packages prepareZIPAtURL:url error:&error];
        NSDictionary *catalog=candidate ? [self.packages catalogWithError:&error] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSError *failure=error; NSDictionary *record=candidate && catalog ? [self recordForCandidate:candidate error:&failure] : nil;
            if (self.stopping) failure=MCPluginError(@"插件导入已取消。");
            if (!record || failure) { [self finishOperation:failure ?: MCPluginError(@"插件包无法读取。") message:@"" completion:completion]; return; }
            NSString *pluginID=record[@"manifest"][@"pluginId"]; NSString *oldDigest=catalog[pluginID];
            if (!oldDigest && catalog.count>=16) { [self finishOperation:MCPluginError(@"当前版本最多安装 16 个插件。") message:@"" completion:completion]; return; }
            [self probeRecord:record index:0 completion:^(NSError *probeError) {
                if (probeError) { [self finishOperation:probeError message:@"" completion:completion]; return; }
                dispatch_async(self.files, ^{
                    NSError *stageError=nil;
                    if (![self.packages stageCandidate:candidate error:&stageError] && !stageError) stageError=MCPluginError(@"插件内容暂存失败。");
                    dispatch_async(dispatch_get_main_queue(), ^{
                        NSMutableDictionary *next=[self.records mutableCopy]; next[pluginID]=record;
                        NSError *commitError=self.stopping ? MCPluginError(@"插件导入已取消。") : stageError;
                        if (!commitError) {
                            BOOL committed=[self.registry replacePluginManifests:[self manifestsForRecords:next] commit:^BOOL(NSError **diskError) {
                                if (self.stopping) { if (diskError) *diskError=MCPluginError(@"插件导入已取消。"); return NO; }
                                if (![self.packages commitCandidate:candidate validatedManifest:record[@"manifest"] expectedDigest:oldDigest error:diskError]) return NO;
                                NSMutableDictionary *installed=[catalog mutableCopy]; installed[pluginID]=candidate.digest;
                                self.lastCatalog=installed; self.records=next; return YES;
                            } error:&commitError];
                            if (!committed && !commitError) commitError=MCPluginError(@"当前编辑状态不允许安装插件，请完成编辑后重试。");
                        }
                        if (!commitError) [self applyToolConfiguration:self.registry.snapshot];
                        [self finishOperation:commitError message:oldDigest ? @"插件已更新，原顺序和开关已保留。" : @"插件已安装，可在截图工具栏使用。" completion:completion];
                    });
                });
            }];
        });
    });
}
- (void)uninstallPlugin:(NSString *)pluginID completion:(void (^)(NSError *))completion {
    if (![self beginOperation:completion]) return;
    NSString *digest=self.lastCatalog[pluginID];
    if (!digest) { [self finishOperation:MCPluginError(@"插件未安装。") message:@"" completion:completion]; return; }
    NSMutableDictionary *next=[self.records mutableCopy]; [next removeObjectForKey:pluginID]; NSError *error=nil;
    BOOL committed=[self.registry replacePluginManifests:[self manifestsForRecords:next] commit:^BOOL(NSError **diskError) {
        if (self.stopping) { if (diskError) *diskError=MCPluginError(@"插件卸载已取消。"); return NO; }
        if (![self.packages uninstallPluginID:pluginID expectedDigest:digest error:diskError]) return NO;
        NSMutableDictionary *installed=[self.lastCatalog mutableCopy]; [installed removeObjectForKey:pluginID];
        self.lastCatalog=installed; self.records=next; return YES;
    } error:&error];
    if (!committed && !error) error=MCPluginError(@"当前编辑状态不允许卸载插件，请完成编辑后重试。");
    if (!error) [self applyToolConfiguration:self.registry.snapshot];
    [self finishOperation:error message:@"插件已卸载，活动调用正在取消；工具偏好保留供重新安装。" completion:completion];
}
- (NSString *)nameForPlugin:(NSString *)pluginID { return self.records[pluginID][@"manifest"][@"name"] ?: pluginID; }
- (NSImage *)iconForPlugin:(NSString *)pluginID { return self.records[pluginID][@"icon"]; }
- (NSDictionary *)enabledTool:(NSString *)identifier {
    for (NSDictionary *tool in [self.registry toolsForGroup:@"screenshot"])
        if ([tool[@"id"] isEqual:identifier] && [tool[@"action"] isEqual:@"run"] && [tool[@"enabled"] boolValue]) return tool;
    return nil;
}
- (BOOL)hasCallsForPlugin:(NSString *)pluginID {
    for (MCUserPluginCall *call in self.calls) if ([call.pluginID isEqual:pluginID]) return YES; return NO;
}
- (void)registryChanged:(__unused NSNotification *)note { [self applyToolConfiguration:self.registry.snapshot]; }
- (void)applyToolConfiguration:(__unused NSDictionary *)snapshot {
    for (MCUserPluginCall *call in self.calls) {
        MCPluginPackageCandidate *current=self.records[call.pluginID][@"package"];
        if (!current || ![current.digest isEqual:call.digest] || ![self enabledTool:call.toolID]) { call.cancelled=YES; [call.worker cancel]; }
    }
    NSMutableSet *plugins=[NSMutableSet setWithArray:self.states.allKeys]; [plugins addObjectsFromArray:self.records.allKeys];
    for (NSString *pluginID in plugins) {
        BOOL enabled=NO;
        for (NSDictionary *tool in [self.registry toolsForGroup:@"screenshot"])
            if ([tool[@"pluginId"] isEqual:pluginID] && [tool[@"enabled"] boolValue] && self.records[pluginID]) { enabled=YES; break; }
        int32_t state=[self.states[pluginID] intValue];
        if (!enabled) state=feature_transition(state,MC_FEATURE_REQUEST_DISABLE);
        if (state==MC_FEATURE_DISABLING && ![self hasCallsForPlugin:pluginID]) state=feature_transition(state,MC_FEATURE_CLEANUP_FINISHED);
        if (enabled && state==MC_FEATURE_DISABLED && !self.stopping) state=feature_transition(state,MC_FEATURE_ENABLE);
        self.states[pluginID]=@(state);
    }
    for (NSDictionary *shown in [self.results copy]) {
        MCPluginPackageCandidate *current=self.records[shown[@"pluginId"]][@"package"];
        if (!current || ![current.digest isEqual:shown[@"digest"]] || ![self enabledTool:shown[@"toolId"]] ||
            !feature_can_invoke([self.states[shown[@"pluginId"]] intValue])) [shown[@"controller"] close];
    }
    for (NSDictionary *result in self.resultLeases.keyEnumerator.allObjects) {
        NSDictionary *lease=[self.resultLeases objectForKey:result];
        MCPluginPackageCandidate *current=self.records[lease[@"pluginId"]][@"package"];
        if (!current || ![current.digest isEqual:lease[@"digest"]] || ![self enabledTool:lease[@"toolId"]]) [self.resultLeases removeObjectForKey:result];
    }
}
- (void)invokeTool:(NSString *)toolID owner:(NSString *)owner capture:(NSDictionary *)capture isCurrent:(BOOL (^)(void))isCurrent completion:(void (^)(NSDictionary *,NSError *))completion {
    NSDictionary *tool=[self enabledTool:toolID]; NSString *pluginID=tool[@"pluginId"]; NSDictionary *record=pluginID ? self.records[pluginID] : nil;
    if (self.stopping || !record || !feature_can_invoke([self.states[pluginID] intValue])) { completion(nil,MCPluginError(@"插件未启用或正在停止。")); return; }
    [self cancelInvocationsForOwner:owner];
    if (self.calls.count>=4) { completion(nil,MCPluginError(@"后台插件任务已满，请稍后重试。")); return; }
    NSString *invocation=NSUUID.UUID.UUIDString; NSError *error=nil;
    NSDictionary *request=[self requestForManifest:record[@"manifest"] tool:toolID invocation:invocation capture:capture error:&error];
    if (!request || !isCurrent()) { completion(nil,error ?: MCPluginError(@"截图已变化，请重试。")); return; }
    MCPluginPackageCandidate *package=record[@"package"]; MCUserPluginCall *call=[MCUserPluginCall new];
    call.pluginID=pluginID; call.toolID=toolID; call.digest=package.digest; call.owner=owner; [self.calls addObject:call];
    call.worker=[MCPluginWorker startWithExecutableURL:self.workerURL wasmData:package.wasmData inputData:[MCJSON(request) dataUsingEncoding:NSUTF8StringEncoding]
        limits:MCPluginWorkerDefaultLimits() completion:^(NSData *output,NSError *failure) {
            MCPluginPackageCandidate *current=self.records[pluginID][@"package"];
            BOOL valid=!call.cancelled && !self.stopping && [current.digest isEqual:call.digest] && [self enabledTool:toolID] && isCurrent();
            [self.calls removeObjectIdenticalTo:call]; [self applyToolConfiguration:self.registry.snapshot];
            NSError *checked=failure; NSDictionary *result=valid && !checked ? MCCheckedOutput(output,invocation,&checked) : nil;
            if (!valid) checked=MCPluginError(@"插件调用已取消或截图已变化。");
            if (result) [self.resultLeases setObject:@{@"pluginId":pluginID,@"toolId":toolID,@"digest":call.digest,@"owner":owner} forKey:result];
            completion(result,checked); [self finishShutdownIfReady];
        }];
}
- (void)cancelInvocationsForOwner:(NSString *)owner {
    for (MCUserPluginCall *call in self.calls) if ([call.owner isEqual:owner]) { call.cancelled=YES; [call.worker cancel]; }
    for (NSDictionary *shown in [self.results copy]) if ([shown[@"owner"] isEqual:owner]) [shown[@"controller"] close];
    for (NSDictionary *result in self.resultLeases.keyEnumerator.allObjects)
        if ([[self.resultLeases objectForKey:result][@"owner"] isEqual:owner]) [self.resultLeases removeObjectForKey:result];
}
- (void)presentResult:(NSDictionary *)result toolID:(NSString *)toolID owner:(NSString *)owner parentWindow:(NSWindow *)window {
    NSDictionary *lease=[self.resultLeases objectForKey:result];
    [self.resultLeases removeObjectForKey:result];
    NSString *pluginID=lease[@"pluginId"];
    MCPluginPackageCandidate *current=pluginID ? self.records[pluginID][@"package"] : nil;
    if (self.stopping || !lease || ![lease[@"toolId"] isEqual:toolID] || ![lease[@"owner"] isEqual:owner] ||
        ![current.digest isEqual:lease[@"digest"]] || ![self enabledTool:toolID] || !feature_can_invoke([self.states[pluginID] intValue])) return;
    MCPluginResultController *controller=[[MCPluginResultController alloc] initWithResult:result pluginName:[self nameForPlugin:pluginID]];
    if (window) { controller.window.level=window.level; [window addChildWindow:controller.window ordered:NSWindowAbove]; }
    NSMutableDictionary *entry=[lease mutableCopy]; entry[@"controller"]=controller; [self.results addObject:entry];
    __weak MCUserPluginManager *weakSelf=self; __weak MCPluginResultController *weakController=controller;
    controller.onClose=^{ for (NSDictionary *item in [weakSelf.results copy]) if (item[@"controller"]==weakController) [weakSelf.results removeObjectIdenticalTo:item]; };
    [controller show];
}
- (void)shutdownWithCompletion:(void (^)(void))completion {
    self.stopping=YES; self.stopped=completion; [self.probe cancel];
    for (MCUserPluginCall *call in self.calls) { call.cancelled=YES; [call.worker cancel]; }
    for (NSDictionary *result in [self.results copy]) [result[@"controller"] close];
    [self.resultLeases removeAllObjects];
    [self finishShutdownIfReady];
}
- (void)finishShutdownIfReady {
    if (self.stopping && !self.busy && self.calls.count==0 && !self.probe && self.stopped) { void (^completion)(void)=self.stopped; self.stopped=nil; completion(); }
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end
