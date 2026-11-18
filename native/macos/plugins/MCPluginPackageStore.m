#import "MCPluginPackageStore.h"
#include "platform/shared/plugin_host/package_zip.h"
#include <CommonCrypto/CommonDigest.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <errno.h>
#include <zlib.h>

NSErrorDomain const MCPluginPackageErrorDomain = @"dev.moojicut.plugin-package";
static const NSUInteger MCCatalogLimit = 1024 * 1024;

static BOOL MCFail(NSError **error, NSInteger code, NSString *message) {
    if (error) *error = [NSError errorWithDomain:MCPluginPackageErrorDomain code:code
                                     userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
static BOOL MCIOFail(NSError **error, NSString *operation) {
    int saved = errno;
    BOOL result = MCFail(error, 2, [NSString stringWithFormat:@"%@：%s", operation, strerror(saved)]);
    errno = saved;
    return result;
}
static BOOL MCDigestIsValid(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] != 64) return NO;
    return [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location == NSNotFound;
}
@interface MCPluginPackageCandidate ()
- (instancetype)initWithManifest:(NSData *)manifest wasm:(NSData *)wasm icon:(nullable NSData *)icon;
@end
@implementation MCPluginPackageCandidate
- (instancetype)initWithManifest:(NSData *)manifest wasm:(NSData *)wasm icon:(NSData *)icon {
    if ((self = [super init])) {
        _manifestData = [manifest copy]; _wasmData = [wasm copy]; _iconData = [icon copy];
        CC_SHA256_CTX context; CC_SHA256_Init(&context);
        const char domain[] = "Mooji Cut package payload v1";
        CC_SHA256_Update(&context, domain, sizeof(domain));
        for (NSString *name in @[@"manifest.json", @"plugin.wasm", @"assets/icon.png"]) {
            NSData *payload = [name isEqual:@"manifest.json"] ? _manifestData : [name isEqual:@"plugin.wasm"] ? _wasmData : _iconData;
            if (!payload) continue;
            NSData *key = [name dataUsingEncoding:NSUTF8StringEncoding];
            CC_SHA256_Update(&context, key.bytes, (CC_LONG)key.length);
            const uint8_t separator = 0;
            CC_SHA256_Update(&context, &separator, 1);
            uint64_t length = CFSwapInt64HostToBig(payload.length);
            CC_SHA256_Update(&context, &length, sizeof(length));
            CC_SHA256_Update(&context, payload.bytes, (CC_LONG)payload.length);
        }
        unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest, &context);
        NSMutableString *hex = [NSMutableString stringWithCapacity:64];
        for (NSUInteger i = 0; i < sizeof(digest); i++) [hex appendFormat:@"%02x", digest[i]];
        _digest = [hex copy];
    }
    return self;
}
@end

static bool MCInflateRaw(void *context, const uint8_t *input, size_t inputSize,
                         uint8_t *output, size_t outputCapacity, size_t *consumed, size_t *written) {
    (void)context;
    z_stream stream = {0};
    stream.next_in = (Bytef *)input;
    stream.avail_in = (uInt)inputSize;
    stream.next_out = output;
    stream.avail_out = (uInt)outputCapacity;
    if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) return false;
    int status = inflate(&stream, Z_FINISH);
    *consumed = stream.total_in;
    *written = stream.total_out;
    return inflateEnd(&stream) == Z_OK && status == Z_STREAM_END;
}

static MCPluginPackageCandidate *MCReadZIP(NSData *data, NSError **error) {
    MCPluginZipPackage package = {0};
    MCPluginZipError zipError;
    if (!mc_plugin_zip_read(data.bytes, data.length, MCInflateRaw, NULL, &package, &zipError)) {
        MCFail(error, 1, [NSString stringWithFormat:@"无法读取插件 ZIP：%s", mc_plugin_zip_error_text(zipError)]);
        return nil;
    }
    NSData *manifest = [NSData dataWithBytes:package.manifest.bytes length:package.manifest.size];
    NSData *wasm = [NSData dataWithBytes:package.wasm.bytes length:package.wasm.size];
    NSData *icon = package.has_icon
        ? [NSData dataWithBytes:package.icon.bytes length:package.icon.size] : nil;
    mc_plugin_zip_clear(&package);
    return [[MCPluginPackageCandidate alloc] initWithManifest:manifest wasm:wasm icon:icon];
}

static NSData *MCReadFD(int fd, NSUInteger limit, NSError **error) {
    struct stat stat;
    if (fstat(fd, &stat) || !S_ISREG(stat.st_mode) || stat.st_size < 0 || (uint64_t)stat.st_size > limit || stat.st_nlink != 1) {
        MCFail(error, 2, @"文件不是普通独立文件，或超过大小限制。"); return nil;
    }
    NSMutableData *data = [NSMutableData data]; uint8_t buffer[32768];
    for (;;) {
        ssize_t length = read(fd, buffer, sizeof(buffer));
        if (length < 0 && errno == EINTR) continue;
        if (length < 0) { MCIOFail(error, @"无法读取文件"); return nil; }
        if (!length) break;
        if ((NSUInteger)length > limit - data.length) { MCFail(error, 2, @"文件读取时超过大小限制。"); return nil; }
        [data appendBytes:buffer length:(NSUInteger)length];
    }
    if (data.length != (NSUInteger)stat.st_size) { MCFail(error, 2, @"文件在读取时发生变化。"); return nil; }
    return [data copy];
}
static NSData *MCReadFile(int parent, const char *name, NSUInteger limit, BOOL optional, NSError **error) {
    int fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) { if (!(optional && errno == ENOENT)) MCIOFail(error, @"无法打开插件文件"); return nil; }
    NSData *data = MCReadFD(fd, limit, error); close(fd); return data;
}
static BOOL MCNamesAllowed(int fd, NSSet *allowed, NSError **error) {
    DIR *directory = fdopendir(dup(fd));
    if (!directory) return MCIOFail(error, @"无法读取插件目录");
    BOOL valid = YES; struct dirent *entry;
    errno = 0;
    while ((entry = readdir(directory))) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        NSString *name = [NSString stringWithUTF8String:entry->d_name];
        if (!name || ![allowed containsObject:name]) { valid = NO; break; }
        errno = 0;
    }
    if (errno) valid = NO;
    closedir(directory);
    if (!valid) MCFail(error, 2, @"安装目录包含未知或无法读取的文件。");
    return valid;
}
static MCPluginPackageCandidate *MCReadPayload(int packages, NSString *digest, NSError **error) {
    int folder = openat(packages, digest.UTF8String, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (folder < 0) { MCIOFail(error, @"无法打开已安装插件"); return nil; }
    BOOL valid = MCNamesAllowed(folder, [NSSet setWithArray:@[@"manifest.json", @"plugin.wasm", @"assets"]], error);
    NSData *manifest = valid ? MCReadFile(folder, "manifest.json", MC_PLUGIN_ZIP_MAX_MANIFEST_BYTES, NO, error) : nil;
    NSData *wasm = manifest ? MCReadFile(folder, "plugin.wasm", MC_PLUGIN_ZIP_MAX_WASM_BYTES, NO, error) : nil;
    NSData *icon = nil;
    int assets = wasm ? openat(folder, "assets", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) : -1;
    if (wasm && assets < 0 && errno != ENOENT) { MCIOFail(error, @"无法读取图标目录"); valid = NO; }
    if (assets >= 0) {
        valid = MCNamesAllowed(assets, [NSSet setWithObject:@"icon.png"], error);
        if (valid) { icon = MCReadFile(assets, "icon.png", MC_PLUGIN_ZIP_MAX_ICON_BYTES, NO, error); valid = icon != nil; }
        close(assets);
    }
    close(folder);
    if (!valid || !manifest || !wasm) return nil;
    MCPluginPackageCandidate *candidate = [[MCPluginPackageCandidate alloc] initWithManifest:manifest wasm:wasm icon:icon];
    if (![candidate.digest isEqual:digest]) { MCFail(error, 2, @"已安装插件内容与摘要不一致。"); return nil; }
    return candidate;
}
static NSDictionary *MCReadCatalog(int root, NSError **error) {
    errno = 0;
    NSData *data = MCReadFile(root, "catalog.json", MCCatalogLimit, YES, error);
    if (!data) return errno == ENOENT ? @{} : nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![object isKindOfClass:NSDictionary.class] || [object count] != 2 ||
        ![object[@"version"] isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)object[@"version"]) == CFBooleanGetTypeID() ||
        ![object[@"version"] isEqual:@1] || ![object[@"packages"] isKindOfClass:NSDictionary.class]) goto invalid;
    for (id key in object[@"packages"]) {
        if (![key isKindOfClass:NSString.class] || ![key length] || [key length] > 255 || !MCDigestIsValid(object[@"packages"][key])) goto invalid;
    }
    return object[@"packages"];
invalid:
    MCFail(error, 2, @"已保存的插件目录索引无效；原数据未被覆盖。"); return nil;
}
static BOOL MCWriteFile(int parent, const char *name, NSData *data, NSError **error) {
    int fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return MCIOFail(error, @"无法创建安装文件");
    const uint8_t *bytes = data.bytes; NSUInteger offset = 0; BOOL valid = YES;
    while (offset < data.length) {
        ssize_t written = write(fd, bytes + offset, data.length - offset);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) { valid = MCIOFail(error, @"无法写入安装文件"); break; }
        offset += (NSUInteger)written;
    }
    if (valid && (fchmod(fd, 0444) || fsync(fd))) valid = MCIOFail(error, @"无法同步安装文件");
    if (close(fd) && valid) valid = MCIOFail(error, @"无法关闭安装文件");
    if (!valid) unlinkat(parent, name, 0);
    return valid;
}
static BOOL MCPublishCatalog(int root, NSDictionary *catalog, NSError **error) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"version":@1, @"packages":catalog} options:NSJSONWritingSortedKeys error:error];
    if (!data || data.length > MCCatalogLimit) return MCFail(error, 2, @"插件索引超过大小限制。");
    NSString *temporary = [@".catalog-" stringByAppendingString:NSUUID.UUID.UUIDString];
    if (!MCWriteFile(root, temporary.UTF8String, data, error)) return NO;
    if (fsync(root) || renameat(root, temporary.UTF8String, root, "catalog.json")) {
        MCIOFail(error, @"无法提交插件索引"); unlinkat(root, temporary.UTF8String, 0); return NO;
    }
    // Rename is the commit point. A later durability failure cannot be reported
    // as an uncommitted transaction; the next reader already sees the new index.
    if (fsync(root)) NSLog(@"Mooji Cut: plugin catalog committed; directory fsync failed: %s", strerror(errno));
    return YES;
}
static BOOL MCOpenDirectory(int parent, const char *name, int *result, NSError **error) {
    if (mkdirat(parent, name, 0700) && errno != EEXIST) return MCIOFail(error, @"无法创建插件目录");
    *result = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    return *result >= 0 || MCIOFail(error, @"无法打开插件目录");
}
static int MCTransactionLock(int root, NSError **error) {
    int fd = openat(root, ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0600);
    if (fd < 0) { MCIOFail(error, @"无法打开插件存储锁"); return -1; }
    struct stat stat;
    if (fstat(fd, &stat) || !S_ISREG(stat.st_mode) || stat.st_nlink != 1) {
        close(fd); MCFail(error, 2, @"插件存储锁不是普通独立文件。"); return -1;
    }
    if (flock(fd, LOCK_EX | LOCK_NB)) {
        close(fd); MCFail(error, MCPluginPackageBusy, @"另一个插件安装操作正在进行，请稍后重试。"); return -1;
    }
    return fd;
}
static void MCRemoveStaging(int parent, const char *name) {
    int folder = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (folder >= 0) {
        fchmod(folder, 0700);
        int assets = openat(folder, "assets", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (assets >= 0) { fchmod(assets, 0700); unlinkat(assets, "icon.png", 0); close(assets); }
        unlinkat(folder, "assets", AT_REMOVEDIR);
        unlinkat(folder, "manifest.json", 0); unlinkat(folder, "plugin.wasm", 0); close(folder);
    }
    unlinkat(parent, name, AT_REMOVEDIR);
}
static BOOL MCInstallPayload(int root, MCPluginPackageCandidate *candidate, NSError **error) {
    int packages = -1;
    if (!MCOpenDirectory(root, "packages", &packages, error)) return NO;
    struct stat existing;
    if (!fstatat(packages, candidate.digest.UTF8String, &existing, AT_SYMLINK_NOFOLLOW)) {
        BOOL valid = MCReadPayload(packages, candidate.digest, error) != nil;
        if (valid && fsync(packages)) valid = MCIOFail(error, @"无法同步插件存储");
        close(packages); return valid;
    }
    if (errno != ENOENT) { close(packages); return MCIOFail(error, @"无法检查安装目录"); }
    NSString *staging = [@".staging-" stringByAppendingString:NSUUID.UUID.UUIDString];
    int folder = -1;
    BOOL valid = MCOpenDirectory(packages, staging.UTF8String, &folder, error);
    if (valid) valid = MCWriteFile(folder, "manifest.json", candidate.manifestData, error) && MCWriteFile(folder, "plugin.wasm", candidate.wasmData, error);
    if (valid && candidate.iconData) {
        int assets = -1;
        valid = MCOpenDirectory(folder, "assets", &assets, error);
        if (valid) {
            valid = MCWriteFile(assets, "icon.png", candidate.iconData, error);
            if (valid && (fchmod(assets, 0555) || fsync(assets))) valid = MCIOFail(error, @"无法同步图标目录");
            close(assets);
        }
    }
    if (valid && (fchmod(folder, 0555) || fsync(folder))) valid = MCIOFail(error, @"无法同步插件目录");
    if (folder >= 0) close(folder);
    if (valid && renameat(packages, staging.UTF8String, packages, candidate.digest.UTF8String)) valid = MCIOFail(error, @"无法安装插件内容");
    if (valid && fsync(packages)) valid = MCIOFail(error, @"无法同步插件存储");
    if (!valid) MCRemoveStaging(packages, staging.UTF8String);
    close(packages); return valid;
}

@interface MCPluginPackageStore ()
@property (nonatomic, copy) NSURL *rootURL;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *stagedPackages;
@property (nonatomic, strong) NSLock *operationLock;
@end
@implementation MCPluginPackageStore
- (instancetype)initWithRootURL:(NSURL *)rootURL {
    NSParameterAssert(rootURL.isFileURL);
    if ((self = [super init])) { _rootURL = [rootURL copy]; _stagedPackages = [NSMutableDictionary dictionary]; _operationLock = [NSLock new]; }
    return self;
}
- (MCPluginPackageCandidate *)prepareZIPAtURL:(NSURL *)url error:(NSError **)error {
    if (error) *error = nil;
    if (!url.isFileURL) { MCFail(error, 1, @"请选择本地 ZIP 文件。"); return nil; }
    int fd = open(url.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) { MCIOFail(error, @"无法打开 ZIP 文件"); return nil; }
    NSData *data = MCReadFD(fd, MC_PLUGIN_ZIP_MAX_BYTES, error); close(fd);
    return data ? MCReadZIP(data, error) : nil;
}
- (int)openRootCreating:(BOOL)create error:(NSError **)error {
    if (create && ![NSFileManager.defaultManager createDirectoryAtURL:self.rootURL withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error]) return -1;
    int root = open(self.rootURL.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (root < 0 && (create || errno != ENOENT)) MCIOFail(error, @"无法打开插件存储");
    return root;
}
- (NSDictionary<NSString *, NSString *> *)catalogWithError:(NSError **)error {
    if (error) *error = nil;
    int root = [self openRootCreating:NO error:error];
    if (root < 0) return errno == ENOENT ? @{} : nil;
    NSDictionary *catalog = MCReadCatalog(root, error); close(root); return catalog;
}
- (MCPluginPackageCandidate *)packageForPluginID:(NSString *)pluginID error:(NSError **)error {
    if (error) *error = nil;
    int root = [self openRootCreating:NO error:error];
    if (root < 0) { if (errno == ENOENT) MCFail(error, 2, @"插件尚未安装。"); return nil; }
    NSDictionary *catalog = MCReadCatalog(root, error);
    NSString *digest = catalog[pluginID];
    if (!digest) { close(root); if (catalog) MCFail(error, 2, @"插件尚未安装。"); return nil; }
    int packages = openat(root, "packages", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); close(root);
    if (packages < 0) { MCIOFail(error, @"无法打开插件内容目录"); return nil; }
    MCPluginPackageCandidate *candidate = MCReadPayload(packages, digest, error); close(packages);
    if (candidate) {
        NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:candidate.manifestData options:0 error:NULL];
        if (![manifest isKindOfClass:NSDictionary.class] || ![manifest[@"pluginId"] isEqual:pluginID]) {
            MCFail(error, 2, @"插件标识与安装索引不一致。"); return nil;
        }
    }
    return candidate;
}
- (BOOL)stageCandidate:(MCPluginPackageCandidate *)candidate error:(NSError **)error {
    if (error) *error = nil;
    if (![self.operationLock tryLock]) return MCFail(error, MCPluginPackageBusy, @"另一个插件安装操作正在进行，请稍后重试。");
    @try {
        [self.stagedPackages removeObjectForKey:candidate.digest];
        int root = [self openRootCreating:YES error:error];
        if (root < 0) return NO;
        int lock = MCTransactionLock(root, error);
        if (lock < 0) { close(root); return NO; }
        BOOL valid = MCInstallPayload(root, candidate, error);
        int packages = valid ? openat(root, "packages", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) : -1;
        struct stat identity;
        if (valid && (packages < 0 || fstatat(packages, candidate.digest.UTF8String, &identity, AT_SYMLINK_NOFOLLOW) || !S_ISDIR(identity.st_mode)))
            valid = MCFail(error, 2, @"暂存插件目录不可用。");
        if (valid) self.stagedPackages[candidate.digest] = @[@(identity.st_dev), @(identity.st_ino)];
        if (packages >= 0) close(packages);
        flock(lock, LOCK_UN); close(lock); close(root); return valid;
    } @finally {
        [self.operationLock unlock];
    }
}
- (BOOL)changePlugin:(NSString *)pluginID candidate:(MCPluginPackageCandidate *)candidate expectedDigest:(NSString *)expected error:(NSError **)error {
    if (![self.operationLock tryLock]) return MCFail(error, MCPluginPackageBusy, @"另一个插件安装操作正在进行，请稍后重试。");
    @try {
        int root = [self openRootCreating:YES error:error];
        if (root < 0) return NO;
        int lock = MCTransactionLock(root, error);
        if (lock < 0) { close(root); return NO; }
        NSDictionary *catalog = MCReadCatalog(root, error);
        BOOL valid = catalog != nil;
        NSString *current = catalog[pluginID];
        if (valid && !((!current && !expected) || [current isEqual:expected])) valid = MCFail(error, 3, @"插件安装状态已变化，请重新操作。");
        if (valid && candidate) {
            NSArray<NSNumber *> *identity = self.stagedPackages[candidate.digest];
            int packages = openat(root, "packages", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            struct stat stat;
            valid = identity && packages >= 0 && !fstatat(packages, candidate.digest.UTF8String, &stat, AT_SYMLINK_NOFOLLOW) &&
                S_ISDIR(stat.st_mode) && identity[0].longLongValue == stat.st_dev && identity[1].unsignedLongLongValue == stat.st_ino;
            if (packages >= 0) close(packages);
            if (!valid) MCFail(error, 4, @"候选插件尚未完成暂存，或暂存目录已变化。");
        }
        if (valid && ![current isEqual:candidate.digest] && (current || candidate)) {
            NSMutableDictionary *next = [catalog mutableCopy];
            if (candidate) next[pluginID] = candidate.digest; else [next removeObjectForKey:pluginID];
            valid = MCPublishCatalog(root, next, error);
        }
        flock(lock, LOCK_UN); close(lock); close(root); return valid;
    } @finally {
        [self.operationLock unlock];
    }
}
- (BOOL)commitCandidate:(MCPluginPackageCandidate *)candidate validatedManifest:(NSDictionary *)manifest expectedDigest:(NSString *)expected error:(NSError **)error {
    if (error) *error = nil;
    id raw = [NSJSONSerialization JSONObjectWithData:candidate.manifestData options:0 error:NULL];
    NSString *pluginID = manifest[@"pluginId"], *version = manifest[@"version"];
    if (![pluginID isKindOfClass:NSString.class] || !pluginID.length || pluginID.length > 255 ||
        ![version isKindOfClass:NSString.class] || !version.length || ![raw isKindOfClass:NSDictionary.class] ||
        ![raw[@"pluginId"] isEqual:pluginID] || ![raw[@"version"] isEqual:version] || (expected && !MCDigestIsValid(expected)))
        return MCFail(error, 1, @"已校验的 manifest 与候选插件不匹配。");
    return [self changePlugin:pluginID candidate:candidate expectedDigest:expected error:error];
}
- (BOOL)uninstallPluginID:(NSString *)pluginID expectedDigest:(NSString *)expected error:(NSError **)error {
    if (error) *error = nil;
    if (!pluginID.length || pluginID.length > 255 || (expected && !MCDigestIsValid(expected))) return MCFail(error, 1, @"插件标识或版本无效。");
    return [self changePlugin:pluginID candidate:nil expectedDigest:expected error:error];
}
@end
