#import <Foundation/Foundation.h>
#import "native/macos/plugins/MCPluginPackageStore.h"
#include <sys/stat.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <zlib.h>

#define CHECK(condition, message) do { if (!(condition)) { fprintf(stderr, "FAIL plugin package: %s\n", message); passed = NO; } } while (0)
static void word(NSMutableData *data, uint16_t value) { uint8_t bytes[] = {(uint8_t)value, (uint8_t)(value >> 8)}; [data appendBytes:bytes length:2]; }
static void dword(NSMutableData *data, uint32_t value) { word(data, (uint16_t)value); word(data, (uint16_t)(value >> 16)); }
static NSData *utf8(NSString *text) { return [text dataUsingEncoding:NSUTF8StringEncoding]; }
static NSDictionary *entry(NSString *name, NSData *data) { return @{@"name":name, @"data":data}; }
static NSData *compressed(NSData *input) {
    z_stream stream = {0};
    if (deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY) != Z_OK) return nil;
    NSMutableData *output = [NSMutableData dataWithLength:compressBound((uLong)input.length)];
    stream.next_in = (Bytef *)input.bytes; stream.avail_in = (uInt)input.length;
    stream.next_out = output.mutableBytes; stream.avail_out = (uInt)output.length;
    int status = deflate(&stream, Z_FINISH);
    NSUInteger length = stream.total_out; deflateEnd(&stream);
    if (status != Z_STREAM_END) return nil;
    output.length = length; return output;
}
// Independent fixture writer: ordinary stored/deflated ZIPs, with deliberately
// malformed names/flags/modes available to exercise the real archive reader.
static NSData *zip(NSArray<NSDictionary *> *entries) {
    NSMutableData *local = [NSMutableData data], *central = [NSMutableData data];
    for (NSDictionary *item in entries) {
        NSData *name = utf8(item[@"name"]), *data = item[@"data"];
        BOOL deflated = [item[@"deflate"] boolValue], descriptor = [item[@"descriptor"] boolValue];
        NSData *packed = deflated ? compressed(data) : data;
        uint32_t size = item[@"size"] ? [item[@"size"] unsignedIntValue] : (uint32_t)data.length;
        uint32_t crc = (uint32_t)crc32(0, data.bytes, (uInt)data.length), offset = (uint32_t)local.length;
        uint16_t flags = [item[@"flags"] unsignedShortValue] | (descriptor ? 8 : 0), method = deflated ? 8 : 0;
        dword(local, 0x04034b50); word(local, 20); word(local, flags); word(local, method); dword(local, 0);
        dword(local, descriptor ? 0 : crc); dword(local, descriptor ? 0 : (uint32_t)packed.length); dword(local, descriptor ? 0 : size);
        word(local, (uint16_t)name.length); word(local, 0); [local appendData:name]; [local appendData:packed];
        if (descriptor) { dword(local, 0x08074b50); dword(local, crc); dword(local, (uint32_t)packed.length); dword(local, size); }
        dword(central, 0x02014b50); word(central, 0x0314); word(central, 20); word(central, flags); word(central, method); dword(central, 0);
        dword(central, crc); dword(central, (uint32_t)packed.length); dword(central, size); word(central, (uint16_t)name.length);
        word(central, 0); word(central, 0); word(central, 0); word(central, 0);
        uint32_t mode = item[@"mode"] ? [item[@"mode"] unsignedIntValue] : ([item[@"name"] hasSuffix:@"/"] ? S_IFDIR | 0755 : S_IFREG | 0644);
        dword(central, mode << 16); dword(central, offset); [central appendData:name];
    }
    uint32_t start = (uint32_t)local.length; [local appendData:central];
    dword(local, 0x06054b50); word(local, 0); word(local, 0); word(local, (uint16_t)entries.count); word(local, (uint16_t)entries.count);
    dword(local, (uint32_t)central.length); dword(local, start); word(local, 0); return local;
}
static NSURL *writeZIP(NSURL *directory, NSData *data) {
    NSURL *url = [directory URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".zip"]];
    return [data writeToURL:url options:0 error:NULL] ? url : nil;
}
static BOOL rejected(MCPluginPackageStore *store, NSURL *directory, NSData *data) {
    NSError *error = nil;
    return [store prepareZIPAtURL:writeZIP(directory, data) error:&error] == nil && error != nil;
}
static NSDictionary *manifest(NSString *version) {
    return @{@"pluginId":@"example.capture", @"name":@"截图信息", @"apiVersion":@1, @"version":version,
        @"runtime":@"extism-1", @"entry":@"plugin.wasm", @"capabilities":@[@"capture.metadata", @"result.text"],
        @"tools":@[@{@"toolId":@"describe", @"title":@"描述截图", @"target":@"screenshot", @"action":@"run"}]};
}
static NSData *json(NSDictionary *value) { return [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:NULL]; }

int main(void) {
    @autoreleasepool {
        BOOL passed = YES;
        NSFileManager *files = NSFileManager.defaultManager;
        NSURL *scratch = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[@"moojicut-package-" stringByAppendingString:NSUUID.UUID.UUIDString]]];
        [files createDirectoryAtURL:scratch withIntermediateDirectories:YES attributes:nil error:NULL];
        NSURL *root = [scratch URLByAppendingPathComponent:@"store"];
        MCPluginPackageStore *store = [[MCPluginPackageStore alloc] initWithRootURL:root];
        NSDictionary *v1 = manifest(@"0.1.0"), *v2 = manifest(@"0.2.0");
        NSData *wasm = [NSData dataWithBytes:"\0asm\1\0\0\0" length:8];
        NSData *icon = utf8(@"opaque PNG bytes: image decoding belongs to the host");
        NSArray *base = @[entry(@"manifest.json", json(v1)), entry(@"plugin.wasm", wasm)];
        NSError *error = nil;
        CHECK([store catalogWithError:&error].count == 0 && !error && ![files fileExistsAtPath:root.path], "read-only discovery does not create storage");
        MCPluginPackageCandidate *first = [store prepareZIPAtURL:writeZIP(scratch, zip(base)) error:&error];
        CHECK(first && !error && [first.wasmData isEqual:wasm] && [first.manifestData isEqual:json(v1)], "ordinary stored ZIP round-trips exact payload bytes");
        CHECK(![files fileExistsAtPath:root.path], "preparing ZIP performs no store writes");
        NSMutableDictionary *deflated = [base[0] mutableCopy]; deflated[@"deflate"] = @YES; deflated[@"descriptor"] = @YES;
        MCPluginPackageCandidate *packed = [store prepareZIPAtURL:writeZIP(scratch, zip(@[deflated, base[1], entry(@"assets/", NSData.data)])) error:&error];
        CHECK(packed && [first.digest isEqual:packed.digest], "digest is independent of compression, descriptors, and an empty assets directory");
        MCPluginPackageCandidate *withIcon = [store prepareZIPAtURL:writeZIP(scratch, zip([base arrayByAddingObject:entry(@"assets/icon.png", icon)])) error:&error];
        CHECK(withIcon && [withIcon.iconData isEqual:icon] && ![withIcon.digest isEqual:first.digest], "optional icon bytes participate in payload identity without decoding");

        CHECK(rejected(store, scratch, zip(@[base[0], base[0], base[1]])), "duplicate entries rejected");
        CHECK(rejected(store, scratch, zip(@[base[1], entry(@"../manifest.json", json(v1))])), "parent traversal rejected");
        CHECK(rejected(store, scratch, zip(@[base[1], entry(@"/manifest.json", json(v1))])), "absolute paths rejected");
        CHECK(rejected(store, scratch, zip([base arrayByAddingObject:entry(@"assets/../escape", NSData.data)])), "extra and normalized aliases rejected");
        CHECK(rejected(store, scratch, zip(@[base[1], entry(@"manifest.json/", json(v1))])), "directory aliases rejected");
        NSMutableDictionary *symlinkEntry = [base[1] mutableCopy]; symlinkEntry[@"mode"] = @(S_IFLNK | 0777);
        CHECK(rejected(store, scratch, zip(@[base[0], symlinkEntry])), "symlink entries rejected");
        NSMutableDictionary *encrypted = [base[1] mutableCopy]; encrypted[@"flags"] = @1;
        CHECK(rejected(store, scratch, zip(@[base[0], encrypted])), "encrypted entries rejected before extraction");
        NSMutableData *badCRC = [zip(base) mutableCopy]; ((uint8_t *)badCRC.mutableBytes)[30 + [@"manifest.json" length]] ^= 1;
        CHECK(rejected(store, scratch, badCRC), "bad CRC fails closed");
        NSMutableData *localAlias = [zip(base) mutableCopy]; ((uint8_t *)localAlias.mutableBytes)[30] = 'x';
        CHECK(rejected(store, scratch, localAlias), "central and local path disagreement rejected");
        NSMutableData *truncated = [zip(base) mutableCopy]; truncated.length--;
        CHECK(rejected(store, scratch, truncated), "truncated ZIP rejected");
        CHECK(rejected(store, scratch, zip(@[base[0], entry(@"plugin.wasm", [NSMutableData dataWithLength:4 * 1024 * 1024 + 1])])), "Wasm payload size limit enforced");
        CHECK(rejected(store, scratch, zip(@[entry(@"manifest.json", [NSMutableData dataWithLength:64 * 1024 + 1]), base[1]])), "manifest size limit enforced");
        CHECK(rejected(store, scratch, zip([base arrayByAddingObject:entry(@"assets/icon.png", [NSMutableData dataWithLength:256 * 1024 + 1])])), "icon size limit enforced");
        NSMutableDictionary *lying = [entry(@"plugin.wasm", [NSMutableData dataWithLength:32768]) mutableCopy]; lying[@"deflate"] = @YES; lying[@"size"] = @1;
        CHECK(rejected(store, scratch, zip(@[base[0], lying])), "actual decompressed size must match declared size");
        NSURL *oversized = writeZIP(scratch, NSData.data);
        int largeFD = open(oversized.fileSystemRepresentation, O_WRONLY); ftruncate(largeFD, 8 * 1024 * 1024 + 1); close(largeFD);
        CHECK(![store prepareZIPAtURL:oversized error:&error] && error, "ZIP input limit is checked before allocating it");
        NSURL *source = writeZIP(scratch, zip(base)), *alias = [scratch URLByAppendingPathComponent:@"source-link.zip"];
        symlink(source.fileSystemRepresentation, alias.fileSystemRepresentation);
        CHECK(![store prepareZIPAtURL:alias error:&error], "source symlink is not followed");
        NSURL *hardlink = [scratch URLByAppendingPathComponent:@"source-hardlink.zip"];
        link(source.fileSystemRepresentation, hardlink.fileSystemRepresentation);
        CHECK(![store prepareZIPAtURL:hardlink error:&error], "source hardlink is not treated as an independent file");
        NSURL *fifo = [scratch URLByAppendingPathComponent:@"input-pipe.zip"];
        mkfifo(fifo.fileSystemRepresentation, 0600);
        CHECK(![store prepareZIPAtURL:fifo error:&error], "nonregular source fails without waiting for a FIFO writer");

        CHECK(![store commitCandidate:first validatedManifest:v1 expectedDigest:nil error:&error] && error.code == MCPluginPackageNotStaged, "commit cannot bypass background staging");
        CHECK([store stageCandidate:first error:&error] && !error, "payload staging succeeds");
        MCPluginPackageStore *reopened = [[MCPluginPackageStore alloc] initWithRootURL:root];
        CHECK([reopened catalogWithError:&error].count == 0 && ![reopened packageForPluginID:@"example.capture" error:&error], "staged orphan is not discovered after restart");
        CHECK(![store commitCandidate:first validatedManifest:v2 expectedDigest:nil error:&error], "validated metadata is bound to exact manifest version");
        CHECK([store commitCandidate:first validatedManifest:v1 expectedDigest:nil error:&error] && !error, "validated and staged candidate commits");
        CHECK([[reopened packageForPluginID:@"example.capture" error:&error].digest isEqual:first.digest], "restart reads only committed catalog and verifies content digest");
        NSURL *catalogURL = [root URLByAppendingPathComponent:@"catalog.json"];
        NSData *oldCatalog = [NSData dataWithContentsOfURL:catalogURL];
        int heldLock = open([root URLByAppendingPathComponent:@".lock"].fileSystemRepresentation, O_RDWR);
        flock(heldLock, LOCK_EX);
        CHECK(![store uninstallPluginID:@"example.capture" expectedDigest:first.digest error:&error] && error.code == MCPluginPackageBusy,
              "publication never blocks the UI waiting for another process's transaction lock");
        flock(heldLock, LOCK_UN); close(heldLock);
        MCPluginPackageCandidate *second = [store prepareZIPAtURL:writeZIP(scratch, zip(@[entry(@"manifest.json", json(v2)), base[1]])) error:&error];
        CHECK([store stageCandidate:second error:&error], "replacement can stage while old version stays active");
        CHECK(![store commitCandidate:second validatedManifest:v2 expectedDigest:nil error:&error] && error.code == MCPluginPackageStale && [[NSData dataWithContentsOfURL:catalogURL] isEqual:oldCatalog], "stale asynchronous completion cannot replace installed version");
        chmod(root.fileSystemRepresentation, 0500);
        BOOL unwritable = [store commitCandidate:second validatedManifest:v2 expectedDigest:first.digest error:&error];
        chmod(root.fileSystemRepresentation, 0700);
        CHECK(!unwritable && [[NSData dataWithContentsOfURL:catalogURL] isEqual:oldCatalog], "pre-commit disk write failure preserves original catalog");
        CHECK([store commitCandidate:second validatedManifest:v2 expectedDigest:first.digest error:&error], "CAS update commits the prepared replacement");
        CHECK([[reopened packageForPluginID:@"example.capture" error:&error].digest isEqual:second.digest], "restart sees the complete replacement");
        CHECK(![store uninstallPluginID:@"example.capture" expectedDigest:first.digest error:&error] && error.code == MCPluginPackageStale, "stale uninstall cannot remove new version");
        CHECK([store uninstallPluginID:@"example.capture" expectedDigest:second.digest error:&error], "uninstall atomically removes only catalog reference");
        CHECK([reopened catalogWithError:&error].count == 0 && [files fileExistsAtPath:[[root URLByAppendingPathComponent:@"packages"] URLByAppendingPathComponent:second.digest].path], "uninstall retains immutable bytes for existing worker leases");
        CHECK(![store commitCandidate:first validatedManifest:v1 expectedDigest:second.digest error:&error] && [reopened catalogWithError:NULL].count == 0, "late probe result cannot resurrect uninstalled plugin");

        CHECK([store commitCandidate:first validatedManifest:v1 expectedDigest:nil error:&error], "explicit fresh install after uninstall succeeds");
        NSURL *installed = [[[root URLByAppendingPathComponent:@"packages"] URLByAppendingPathComponent:first.digest] URLByAppendingPathComponent:@"plugin.wasm"];
        chmod(installed.fileSystemRepresentation, 0644); [utf8(@"tampered") writeToURL:installed options:0 error:NULL];
        CHECK(![reopened packageForPluginID:@"example.capture" error:&error] && error, "modified installed bytes fail digest verification");
        CHECK(![store stageCandidate:first error:&error], "existing content-addressed package cannot hide corrupted payload");
        NSData *committed = [NSData dataWithContentsOfURL:catalogURL];
        chmod(catalogURL.fileSystemRepresentation, 0644); [utf8(@"{\"version\":1,\"packages\":{\"bad\":\"../escape\"}}") writeToURL:catalogURL options:0 error:NULL];
        CHECK(![reopened catalogWithError:&error] && error && ![store uninstallPluginID:@"example.capture" expectedDigest:first.digest error:&error], "corrupt catalog fails closed instead of being reset");
        [committed writeToURL:catalogURL options:0 error:NULL];
        // Installed payloads are intentionally read-only. Restore directory
        // permissions solely for fixture teardown, never in the product loader.
        NSDirectoryEnumerator *enumerator = [files enumeratorAtURL:scratch includingPropertiesForKeys:nil options:0 errorHandler:nil];
        for (NSURL *url in enumerator) { BOOL directory = NO; [files fileExistsAtPath:url.path isDirectory:&directory]; if (directory) chmod(url.fileSystemRepresentation, 0700); }
        [files removeItemAtURL:scratch error:NULL];
        if (passed) puts("plugin package: ZIP boundaries, atomic staging/CAS, restart, and uninstall passed");
        return passed ? 0 : 1;
    }
}
