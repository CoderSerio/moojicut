#import "MCUserPluginManager.h"
#import "MCPluginResultController.h"
#import "native/macos/preferences/MCToolRegistryStore.h"
#include "platform/shared/plugin_host/desktop.h"
#include "bindings/c/tool_registry.h"
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

NSNotificationName const MCUserPluginsDidChangeNotification = @"MCUserPluginsDidChangeNotification";
static NSError *MCPluginError(NSString *message) {
    return [NSError errorWithDomain:@"dev.moojicut.user-plugins" code:1
        userInfo:@{NSLocalizedDescriptionKey:message ?: @"插件操作失败。"}];
}
static NSString *MCJSON(id object) {
    NSData *bytes=[NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
    return bytes ? [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding] : nil;
}
static NSDictionary *MCRegistry(const char *json) {
    if (!json) return nil;
    NSData *bytes=[NSData dataWithBytes:json length:strlen(json)];
    id value=[NSJSONSerialization JSONObjectWithData:bytes options:0 error:NULL];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
// Pure bounded platform utilities; the shared driver may call these off-main.
static bool MCReadZIP(const char *path,uint8_t **output,size_t *size,char error[256]) {
    int fd=open(path,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK);
    if (fd<0) { snprintf(error,256,"Cannot open plugin ZIP: %s",strerror(errno)); return false; }
    struct stat info;
    bool valid=fstat(fd,&info)==0 && S_ISREG(info.st_mode) && info.st_size>0 && info.st_size<=MC_PLUGIN_ZIP_MAX_BYTES;
    uint8_t *bytes=valid ? malloc((size_t)info.st_size) : NULL;
    size_t length=valid ? (size_t)info.st_size : 0, offset=0;
    if (!bytes) valid=false;
    while (valid && offset<length) {
        ssize_t count=read(fd,bytes+offset,length-offset);
        if (count<0 && errno==EINTR) continue;
        if (count<=0) { valid=false; break; }
        offset+=(size_t)count;
    }
    if (valid) {
        uint8_t extra; ssize_t count;
        do { count=read(fd,&extra,1); } while (count<0 && errno==EINTR);
        valid=count==0;
    }
    if (close(fd)) valid=false;
    if (!valid) { free(bytes); snprintf(error,256,"Plugin ZIP must be a readable, bounded regular file (at most 8 MiB)"); return false; }
    *output=bytes; *size=length; return true;
}
static bool MCSHA256(const uint8_t *bytes,size_t size,char digest[65]) {
    if (size>MC_PLUGIN_ZIP_MAX_BYTES || (!bytes && size)) return false;
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    if (!CC_SHA256(bytes,(CC_LONG)size,hash)) return false;
    static const char digits[]="0123456789abcdef";
    for (size_t i=0;i<sizeof(hash);i++) { digest[i*2]=digits[hash[i]>>4]; digest[i*2+1]=digits[hash[i]&15]; }
    digest[64]=0; return true;
}
static bool MCInflate(void *context,const uint8_t *input,size_t size,uint8_t *output,size_t capacity,
                      size_t *consumed,size_t *written) {
    (void)context;
    if (size>UINT_MAX || capacity>UINT_MAX) return false;
    z_stream stream={0}; stream.next_in=(Bytef *)input; stream.avail_in=(uInt)size;
    stream.next_out=output; stream.avail_out=(uInt)capacity;
    if (inflateInit2(&stream,-MAX_WBITS)!=Z_OK) return false;
    int result=inflate(&stream,Z_FINISH);
    *consumed=(size_t)stream.total_in; *written=(size_t)stream.total_out;
    int closed=inflateEnd(&stream); return result==Z_STREAM_END && closed==Z_OK;
}
static NSImage *MCPluginIcon(const uint8_t *bytes,size_t size) {
    static const uint8_t magic[]={137,80,78,71,13,10,26,10};
    if (!bytes || size<24 || size>MC_PLUGIN_ZIP_MAX_ICON_BYTES || memcmp(bytes,magic,8) || memcmp(bytes+12,"IHDR",4)) return nil;
    uint32_t width=((uint32_t)bytes[16]<<24)|((uint32_t)bytes[17]<<16)|((uint32_t)bytes[18]<<8)|bytes[19];
    uint32_t height=((uint32_t)bytes[20]<<24)|((uint32_t)bytes[21]<<16)|((uint32_t)bytes[22]<<8)|bytes[23];
    if (!width || !height || width>512 || height>512) return nil;
    NSBitmapImageRep *bitmap=[NSBitmapImageRep imageRepWithData:[NSData dataWithBytes:bytes length:size]];
    if (!bitmap || bitmap.pixelsWide!=width || bitmap.pixelsHigh!=height) return nil;
    NSImage *image=[[NSImage alloc] initWithSize:NSMakeSize(20,20)]; [image addRepresentation:bitmap]; return image;
}

@interface MCUserPluginManager ()
@property MCToolRegistryStore *registry;
@property NSURL *rootURL;
@property NSURL *workerURL;
@property MCDesktopPlugins *driver;
@property NSTimer *timer;
@property BOOL loading;
@property BOOL stopping;
@property BOOL lastBusy;
@property BOOL servicing;
@property (nonatomic,copy,readwrite) NSString *statusMessage;
@property NSError *lastError;
@property NSMutableArray<NSDictionary *> *results;
@property NSMutableDictionary<NSString *,NSImage *> *icons;
@property NSDictionary *pendingSnapshot;
@property (copy) void (^operation)(NSError *);
@property BOOL operationReady;
@property BOOL operationSucceeded;
@property NSMutableArray<void (^)(void)> *closeCompletions;
@property MCUserPluginManager *lease;
- (void)pump;
- (BOOL)performCommand:(NSDictionary *)command error:(NSError **)error;
- (void)receiveResult:(int32_t)capture tool:(NSString *)tool title:(NSString *)title text:(NSString *)text changed:(BOOL)changed;
@end

static bool MCPreflight(void *context,int32_t snapshot,const char *json) {
    (void)snapshot;
    MCUserPluginManager *manager=(__bridge MCUserPluginManager *)context;
    NSDictionary *candidate=MCRegistry(json); NSError *error=nil;
    if (!candidate || ![manager.registry prepareManagedSnapshot:candidate error:&error]) {
        manager.lastError=error ?: MCPluginError(@"请先完成当前截图编辑，再调整插件。"); return false;
    }
    manager.pendingSnapshot=candidate; return true;
}
static void MCPublish(void *context,int32_t snapshot,const char *json) {
    MCUserPluginManager *manager=(__bridge MCUserPluginManager *)context;
    NSDictionary *candidate=manager.pendingSnapshot ?: MCRegistry(json);
    manager.pendingSnapshot=nil;
    [manager.icons removeAllObjects];
    [manager.registry publishManagedSnapshot:candidate];
    tool_registry_snapshot_close(snapshot);
    // Accepted text results are native windows, not live plugin instances.
    // A new catalog retires their presentation along with the old projection.
    for (NSDictionary *entry in [manager.results copy]) [entry[@"controller"] close];
    [NSNotificationCenter.defaultCenter postNotificationName:MCUserPluginsDidChangeNotification object:manager];
}
static void MCDiscard(void *context) {
    MCUserPluginManager *manager=(__bridge MCUserPluginManager *)context;
    manager.pendingSnapshot=nil;
    if (manager.registry.discardChange) manager.registry.discardChange();
}
static void MCMessage(void *context,const char *text,bool error) {
    MCUserPluginManager *manager=(__bridge MCUserPluginManager *)context;
    manager.statusMessage=text ? [NSString stringWithUTF8String:text] : @"";
    if (error) manager.lastError=MCPluginError(manager.statusMessage);
    [NSNotificationCenter.defaultCenter postNotificationName:MCUserPluginsDidChangeNotification object:manager];
}
static void MCResult(void *context,int32_t capture,const char *tool,const char *title,const char *text,bool changed) {
    MCUserPluginManager *manager=(__bridge MCUserPluginManager *)context;
    [manager receiveResult:capture tool:tool ? [NSString stringWithUTF8String:tool] : @"" title:title ? [NSString stringWithUTF8String:title] : @"插件结果"
        text:text ? [NSString stringWithUTF8String:text] : @"" changed:changed];
}
static void MCImportComplete(void *context,bool success) {
    MCUserPluginManager *manager=(__bridge MCUserPluginManager *)context;
    manager.operationReady=YES; manager.operationSucceeded=success;
}

@implementation MCUserPluginManager
- (instancetype)initWithRegistry:(MCToolRegistryStore *)registry rootURL:(NSURL *)rootURL workerURL:(NSURL *)workerURL {
    NSParameterAssert(NSThread.isMainThread);
    if ((self=[super init])) {
        _registry=registry; _rootURL=rootURL; _workerURL=workerURL;
        _statusMessage=@""; _results=[NSMutableArray array]; _icons=[NSMutableDictionary dictionary];
        _closeCompletions=[NSMutableArray array];
        __weak MCUserPluginManager *weakSelf=self;
        registry.managedCommand=^BOOL(NSDictionary *command,NSError **error) {
            MCUserPluginManager *manager=weakSelf;
            if (!manager) { if (error) *error=MCPluginError(@"插件服务已经关闭。"); return NO; }
            return [manager performCommand:command error:error];
        };
    }
    return self;
}
- (BOOL)isBusy { return self.loading || self.operation || (self.driver && mc_desktop_plugins_busy(self.driver)); }
- (NSArray<NSString *> *)installedPluginIDs { return [self.registry.pluginManifests valueForKey:@"pluginId"] ?: @[]; }
- (NSString *)nameForPlugin:(NSString *)pluginID {
    for (NSDictionary *manifest in self.registry.pluginManifests)
        if ([manifest[@"pluginId"] isEqual:pluginID]) return manifest[@"name"];
    return pluginID;
}
- (NSImage *)iconForPlugin:(NSString *)pluginID {
    if (!self.driver) return nil;
    NSImage *icon=self.icons[pluginID];
    if (!icon) {
        size_t size=0; const uint8_t *bytes=mc_desktop_plugins_icon(self.driver,pluginID.UTF8String,&size);
        icon=MCPluginIcon(bytes,size); if (icon) self.icons[pluginID]=icon;
    }
    return icon;
}
- (void)loadInstalledPluginsWithCompletion:(void (^)(NSError *))completion {
    NSAssert(NSThread.isMainThread,@"Plugin application belongs to the main thread");
    if (self.driver || self.loading || self.stopping) { completion(MCPluginError(@"插件服务已启动或正在关闭。")); return; }
    self.loading=YES; self.lease=self; self.lastError=nil;
    [NSNotificationCenter.defaultCenter postNotificationName:MCUserPluginsDidChangeNotification object:self];
    NSURL *parent=[self.rootURL URLByDeletingLastPathComponent];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NSError *error=nil;
        BOOL ready=[NSFileManager.defaultManager createDirectoryAtURL:parent withIntermediateDirectories:YES
            attributes:@{NSFilePosixPermissions:@0700} error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ready && !self.stopping) {
                NSString *layout=MCJSON(self.registry.snapshot[@"layout"]);
                MCDesktopPluginHooks hooks={(__bridge void *)self,MCPreflight,MCPublish,MCDiscard,MCMessage,MCResult,MCImportComplete};
                MCDesktopPluginPlatform platform={MCReadZIP,MCSHA256,MCInflate};
                self.driver=mc_desktop_plugins_open_with_platform(self.rootURL.fileSystemRepresentation,
                    self.workerURL.fileSystemRepresentation,layout.UTF8String,
                    MC_TOOL_CAP_COMMANDS|MC_TOOL_CAP_USER|MC_TOOL_CAP_OCR|MC_TOOL_CAP_TRANSLATE,&hooks,&platform);
            }
            self.loading=NO;
            NSError *failure=error ?: (self.driver ? nil : self.lastError ?: MCPluginError(@"插件服务无法启动，原安装索引未修改。"));
            if (failure) { self.lastError=failure; self.statusMessage=failure.localizedDescription; }
            if (self.driver) {
                __weak MCUserPluginManager *weakSelf=self;
                self.timer=[NSTimer timerWithTimeInterval:0.02 repeats:YES block:^(__unused NSTimer *timer) { [weakSelf pump]; }];
                [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
            } else self.lease=nil;
            completion(failure);
            [NSNotificationCenter.defaultCenter postNotificationName:MCUserPluginsDidChangeNotification object:self];
            [self pump];
        });
    });
}
- (BOOL)available:(NSError **)error {
    if (self.driver && !self.stopping && !self.loading && !self.operation) return YES;
    if (error) *error=MCPluginError(@"插件服务尚未就绪或操作正在进行。"); return NO;
}
- (BOOL)performCommand:(NSDictionary *)command error:(NSError **)error {
    NSAssert(NSThread.isMainThread,@"Plugin settings belong to the main thread");
    if (![self available:error]) return NO;
    self.lastError=nil; BOOL accepted=NO;
    if ([command[@"type"] isEqual:@"enabled"])
        accepted=mc_desktop_plugins_enabled(self.driver,[command[@"id"] UTF8String],[command[@"enabled"] boolValue]);
    else if ([command[@"type"] isEqual:@"move"])
        accepted=mc_desktop_plugins_move(self.driver,[command[@"id"] UTF8String],
            [command[@"beforeId"] isKindOfClass:NSString.class] ? [command[@"beforeId"] UTF8String] : "");
    if (!accepted && error) *error=self.lastError ?: MCPluginError(@"工具设置尚未保存，请重试。");
    return accepted;
}
- (void)importZIPAtURL:(NSURL *)url completion:(void (^)(NSError *))completion {
    NSError *error=nil;
    if (![self available:&error]) { completion(error); return; }
    self.lastError=nil; self.operation=completion; self.operationReady=NO; self.operationSucceeded=NO;
    if (!url.isFileURL || !mc_desktop_plugins_import(self.driver,url.fileSystemRepresentation)) {
        self.operation=nil; completion(self.lastError ?: MCPluginError(@"无法开始导入插件。"));
    }
    [self pump];
}
- (void)uninstallPlugin:(NSString *)pluginID completion:(void (^)(NSError *))completion {
    NSError *error=nil;
    if (![self available:&error]) { completion(error); return; }
    self.lastError=nil;
    BOOL accepted=mc_desktop_plugins_uninstall(self.driver,pluginID.UTF8String);
    completion(accepted ? nil : self.lastError ?: MCPluginError(@"无法卸载插件。"));
    [self pump];
}
- (BOOL)invokeTool:(NSString *)toolID payload:(NSString *)payload capture:(int32_t)capture {
    NSAssert(NSThread.isMainThread,@"Plugin dispatch belongs to the main thread");
    if (!self.driver || self.stopping) return NO;
    BOOL accepted=mc_desktop_plugins_invoke(self.driver,capture,toolID.UTF8String,payload.UTF8String);
    // Let the toolbar ACK this dispatch before any terminal worker result is
    // consumed. The existing main-run-loop timer pumps the asynchronous call.
    [NSNotificationCenter.defaultCenter postNotificationName:MCUserPluginsDidChangeNotification object:self];
    return accepted;
}
- (void)closeCapture:(int32_t)capture {
    if (self.driver && capture>0) mc_desktop_plugins_close_capture(self.driver,capture);
    for (NSDictionary *entry in [self.results copy]) if ([entry[@"capture"] intValue]==capture) [entry[@"controller"] close];
    [self pump];
}
- (void)receiveResult:(int32_t)capture tool:(NSString *)tool title:(NSString *)title text:(NSString *)text changed:(BOOL)changed {
    if (self.stopping) return;
    NSWindow *window=self.windowForCapture ? self.windowForCapture(capture) : nil;
    if (!window) return;
    if (changed) { if (self.documentChanged) self.documentChanged(capture); return; }
    NSString *scope=[tool componentsSeparatedByString:@"/"].firstObject;
    NSString *pluginID=[scope hasPrefix:@"user."] ? [scope substringFromIndex:5] : @"";
    MCPluginResultController *controller=[[MCPluginResultController alloc] initWithResult:@{@"title":title,@"text":text}
        pluginName:[self nameForPlugin:pluginID] ?: @"插件"];
    controller.window.level=window.level; [window addChildWindow:controller.window ordered:NSWindowAbove];
    NSDictionary *entry=@{@"capture":@(capture),@"tool":tool,@"controller":controller}; [self.results addObject:entry];
    __weak MCUserPluginManager *weakSelf=self; __weak MCPluginResultController *weakController=controller;
    controller.onClose=^{ for (NSDictionary *item in [weakSelf.results copy])
        if (item[@"controller"]==weakController) [weakSelf.results removeObjectIdenticalTo:item]; };
    [controller show];
}
- (void)pump {
    __attribute__((objc_precise_lifetime)) MCUserPluginManager *keepAlive=self;
    (void)keepAlive;
    if (self.servicing) return;
    self.servicing=YES;
    if (self.driver) mc_desktop_plugins_pump(self.driver);
    if (self.operation && self.operationReady) {
        void (^completion)(NSError *)=self.operation; self.operation=nil;
        self.operationReady=NO;
        completion(self.operationSucceeded ? nil : self.lastError ?: MCPluginError(self.stopping ? @"插件导入已取消。" : @"插件未安装。"));
    }
    if (self.stopping && !self.loading && !self.operation && mc_desktop_plugins_close(self.driver)) {
        self.driver=NULL; [self.timer invalidate]; self.timer=nil;
        NSArray *completions=[self.closeCompletions copy]; [self.closeCompletions removeAllObjects];
        self.lease=nil;
        for (void (^completion)(void) in completions) completion();
    }
    BOOL busy=self.busy;
    if (busy!=self.lastBusy) {
        self.lastBusy=busy;
        [NSNotificationCenter.defaultCenter postNotificationName:MCUserPluginsDidChangeNotification object:self];
    }
    self.servicing=NO;
}
- (void)shutdownWithCompletion:(void (^)(void))completion {
    self.stopping=YES; [self.closeCompletions addObject:[completion copy]];
    for (NSDictionary *entry in [self.results copy]) [entry[@"controller"] close];
    // close starts cancellation immediately; keep pumping until actual drain.
    if (self.driver && mc_desktop_plugins_close(self.driver)) self.driver=NULL;
    [self pump];
}
@end
