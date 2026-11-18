#import <Foundation/Foundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <unistd.h>
#include "bindings/c/image_session.h"
#include "bindings/c/plugin_application.h"
#include "native/macos/plugins/MCPluginPackageStore.h"
#include "platform/shared/plugin_host/package_store.h"
#include "platform/shared/plugin_host/worker_process.h"

static NSString *JSON(id value) {
    NSError *error = nil;
    NSData *bytes = [NSJSONSerialization dataWithJSONObject:value options:0 error:&error];
    NSCAssert(bytes && !error, @"Encode command: %@", error);
    return [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
}

static moonbit_string_t MoonString(NSString *text) {
    NSCAssert(text.length <= INT32_MAX, @"Input is bounded");
    moonbit_string_t input = moonbit_make_string_raw((int32_t)text.length);
    [text getCharacters:input range:NSMakeRange(0, text.length)];
    return input;
}

static NSDictionary *TakeResponse(moonbit_string_t value) {
    NSString *text = [[NSString alloc] initWithCharacters:value length:(NSUInteger)Moonbit_array_length(value)];
    moonbit_decref(value);
    NSError *error = nil;
    NSDictionary *response = [NSJSONSerialization JSONObjectWithData:
        [text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:&error];
    NSCAssert([response isKindOfClass:NSDictionary.class] && !error, @"Decode response: %@", error);
    return response;
}

static NSDictionary *Send(int32_t app, NSDictionary *command) {
    moonbit_string_t request = MoonString(JSON(command));
    NSDictionary *response = TakeResponse(plugin_application_request(app, request));
    moonbit_decref(request);
    return response;
}

static NSDictionary *Require(int32_t app, NSDictionary *command) {
    NSDictionary *response = Send(app, command);
    NSCAssert([response[@"ok"] boolValue], @"Plugin command %@: %@", command[@"op"], response);
    return response;
}

static int32_t Open(NSString *index, NSArray *archives) {
    moonbit_string_t saved = MoonString(index);
    moonbit_string_t verified = MoonString(JSON(@{@"archives": archives}));
    moonbit_string_t layout = MoonString(@"{\"version\":1,\"groups\":{}}");
    NSDictionary *response = TakeResponse(plugin_application_open(saved, verified, layout));
    moonbit_decref(saved);
    moonbit_decref(verified);
    moonbit_decref(layout);
    int32_t app = [response[@"application"] intValue];
    NSCAssert(app > 0, @"Open plugin application: %@", response);
    return app;
}

static NSString *Text(NSData *data) {
    NSString *value = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSCAssert(value, @"Expected UTF-8 bytes");
    return value;
}

static NSString *Digest(NSData *data) {
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, bytes);
    NSMutableString *text = [NSMutableString stringWithCapacity:64];
    for (size_t i = 0; i < sizeof(bytes); i++) [text appendFormat:@"%02x", bytes[i]];
    return text;
}

static NSString *RunWorker(NSString *worker, NSData *wasm, NSString *requestJSON) {
    NSData *input = [requestJSON dataUsingEncoding:NSUTF8StringEncoding];
    MCPluginProcessRequest request = {
        .executable = worker.fileSystemRepresentation, .wasm = wasm.bytes, .input = input.bytes,
        .wire = {
            .wasm_size = wasm.length, .input_size = input.length,
            .max_output_bytes = MC_WASM_MAX_OUTPUT_BYTES, .fuel = MC_WASM_MAX_FUEL,
            .timeout_ms = MC_WASM_MAX_TIMEOUT_MS, .max_memory_pages = MC_WASM_MAX_MEMORY_PAGES,
        },
        .max_stderr_bytes = 4096, .wall_ms = 5000,
    };
    MCPluginProcess *process = mc_plugin_process_start(&request);
    NSCAssert(process, @"Start plugin worker");
    MCPluginProcessResult result;
    MCPluginProcessStatus status;
    while ((status = mc_plugin_process_poll(process, &result)) == MC_PLUGIN_PROCESS_RUNNING) {
        usleep(2000);
    }
    NSCAssert(status == MC_PLUGIN_PROCESS_OK, @"Plugin worker status %d", status);
    NSString *output = Text([NSData dataWithBytes:result.output length:result.output_size]);
    NSCAssert(mc_plugin_process_close(process), @"Worker resources drained");
    return output;
}

static void Publish(int32_t app, const char *path, NSDictionary *reservation) {
    BOOL exists = reservation[@"expected"] != NSNull.null;
    NSData *expected = exists ? [reservation[@"expected"] dataUsingEncoding:NSUTF8StringEncoding] : nil;
    NSData *index = [reservation[@"next"] dataUsingEncoding:NSUTF8StringEncoding];
    MCPluginStoreStatus status = mc_plugin_store_replace_snapshot(
        path, exists, expected.bytes, expected.length, index.bytes, index.length, NULL);
    NSCAssert(status == MC_PLUGIN_STORE_OK, @"Commit one atomic package and layout index, status %d", status);
    NSCAssert([Require(app, @{@"op":@"publishComplete", @"ticket":reservation[@"ticket"], @"saved":@YES})[@"published"] boolValue],
              @"Acknowledge the durable commit");
}

static NSString *ReadIndex(const char *path) {
    MCPluginStoreBytes snapshot = {0};
    NSCAssert(mc_plugin_store_read_snapshot(path, &snapshot, NULL) == MC_PLUGIN_STORE_OK, @"Restore index");
    NSString *index = Text([NSData dataWithBytes:snapshot.bytes length:snapshot.size]);
    mc_plugin_store_bytes_free(&snapshot);
    return index;
}

static void CheckInstall(NSString *root, NSString *worker, NSURL *zipURL) {
    MCPluginPackageStore *reader = [[MCPluginPackageStore alloc] initWithRootURL:
        [NSURL fileURLWithPath:root isDirectory:YES]];
    NSError *error = nil;
    MCPluginPackageCandidate *candidate = [reader prepareZIPAtURL:zipURL error:&error];
    NSCAssert(candidate && !error, @"Read the real package: %@", error);
    NSData *zip = [NSData dataWithContentsOfURL:zipURL];
    NSString *digest = Digest(zip);
    const char *path = root.fileSystemRepresentation;
    NSCAssert(mc_plugin_store_stage_zip(path, digest.UTF8String, zip.bytes, zip.length, NULL) == MC_PLUGIN_STORE_OK,
              @"Stage the immutable archive");
    NSString *manifest = Text(candidate.manifestData);
    NSString *numbered = @"user.com.moojicut.examples.numbered-box/numbered-box";
    NSString *describe = @"user.com.moojicut.examples.numbered-box/describe";
    int32_t app = Open(@"", @[]);
    NSDictionary *prepare = Require(app, @{@"op":@"prepareInstall", @"manifest":manifest,
        @"digest":digest, @"granted":@[numbered, describe]});
    NSString *health = RunWorker(worker, candidate.wasmData, prepare[@"request"]);
    NSDictionary *ack = @{@"op":@"healthComplete", @"ticket":prepare[@"ticket"], @"output":health};
    NSCAssert([Require(app, ack)[@"ready"] boolValue], @"Healthy package");
    NSCAssert(![Send(app, ack)[@"ok"] boolValue], @"Duplicate health leaves the ready installation intact");
    NSDictionary *reserve = Require(app, @{@"op":@"reserveInstall", @"ticket":prepare[@"ticket"]});
    NSCAssert(reserve[@"expected"] == NSNull.null, @"A fresh install expects no durable index");
    NSCAssert([reserve[@"registry"][@"groups"][@"screenshot"] count] > 0, @"Prepare tool projection before touching disk");
    Publish(app, path, reserve);
    NSCAssert(plugin_application_close(app), @"Close after installation drained");

    MCPluginStoreBytes restoredZip = {0};
    NSCAssert(mc_plugin_store_read_zip(path, digest.UTF8String, &restoredZip, NULL) == MC_PLUGIN_STORE_OK, @"Restore package");
    NSData *verifiedZip = [NSData dataWithBytes:restoredZip.bytes length:restoredZip.size];
    NSCAssert([Digest(verifiedZip) isEqual:digest] && [verifiedZip isEqual:zip], @"Verify the restored archive");
    mc_plugin_store_bytes_free(&restoredZip);
    NSArray *verified = @[@{@"manifest":manifest, @"digest":digest}];
    app = Open(ReadIndex(path), verified);
    int32_t capture = image_session_create_viewport(640, 480, 90, 60, 320, 180);
    NSCAssert(capture > 0, @"Create a real screenshot session");
    NSDictionary *annotations = Require(app, @{@"op":@"startCall", @"capture":@(capture), @"tool":numbered,
        @"selection":@{@"x":@8, @"y":@12, @"width":@64, @"height":@32}});
    NSDictionary *text = Require(app, @{@"op":@"startCall", @"capture":@(capture), @"tool":describe, @"selection":NSNull.null});
    NSString *description = RunWorker(worker, candidate.wasmData, text[@"request"]);
    NSDictionary *result = Require(app, @{@"op":@"finishCall", @"ticket":text[@"ticket"], @"output":description});
    NSCAssert([result[@"text"] isEqual:@"320 × 180 像素"] && image_session_count(capture) == 0, @"Text has no document side effect");
    NSString *output = RunWorker(worker, candidate.wasmData, annotations[@"request"]);
    NSDictionary *finish = @{@"op":@"finishCall", @"ticket":annotations[@"ticket"], @"output":output};
    NSCAssert([Require(app, finish)[@"result"] isEqual:@"documentChanged"], @"Apply the external rectangle and label");
    NSCAssert(![Send(app, finish)[@"ok"] boolValue], @"A transport retry cannot write a second result");
    NSCAssert(image_session_count(capture) == 2 && image_session_undo(capture) == 1 &&
              image_session_count(capture) == 0, @"One native undo reverses the entire effect");

    NSDictionary *invalid = Require(app, @{@"op":@"startCall", @"capture":@(capture), @"tool":describe,
        @"selection":NSNull.null});
    NSUInteger controlCount = MC_WASM_MAX_OUTPUT_BYTES;
    unichar *controls = calloc(controlCount, sizeof(*controls));
    NSCAssert(controls, @"Allocate the bounded worker-output fixture");
    NSString *invalidOutput = [[NSString alloc] initWithCharacters:controls length:controlCount];
    free(controls);
    NSDictionary *invalidResult = Send(app, @{@"op":@"finishCall", @"ticket":invalid[@"ticket"],
        @"output":invalidOutput});
    NSCAssert(![invalidResult[@"ok"] boolValue] && [Require(app, @{@"op":@"status"})[@"quiescent"] boolValue],
              @"Reject malformed output after acknowledging the drained worker");

    NSDictionary *move = Require(app, @{@"op":@"reserveToolChange", @"command":
        @{@"type":@"move", @"id":describe, @"group":@"screenshot", @"beforeId":numbered}});
    NSArray *toolIDs = [move[@"registry"][@"groups"][@"screenshot"] valueForKey:@"id"];
    NSCAssert([toolIDs containsObject:describe] && [toolIDs indexOfObject:describe] < [toolIDs indexOfObject:numbered],
              @"Publish package ordering using the normal catalogue");
    Publish(app, path, move);

    NSDictionary *late = Require(app, @{@"op":@"startCall", @"capture":@(capture), @"tool":numbered,
        @"selection":@{@"x":@8, @"y":@12, @"width":@64, @"height":@32}});
    NSDictionary *staleUpgrade = Require(app, @{@"op":@"prepareInstall", @"manifest":manifest,
        @"digest":digest, @"granted":@[numbered, describe]});
    NSDictionary *disable = Require(app, @{@"op":@"reserveToolChange", @"command":
        @{@"type":@"enabled", @"id":numbered, @"enabled":@NO}});
    NSCAssert(![Require(app, @{@"op":@"status"})[@"cancel"] containsObject:late[@"ticket"]],
              @"A prepared change leaves existing invocation alive");
    Publish(app, path, disable);
    NSCAssert(![Require(app, @{@"op":@"healthComplete", @"ticket":staleUpgrade[@"ticket"],
        @"output":health})[@"ready"] boolValue], @"A changed grant makes an earlier install ticket stale");
    NSCAssert([Require(app, @{@"op":@"status"})[@"cancel"] containsObject:late[@"ticket"]],
              @"A durable disable requests cancellation");
    NSString *lateOutput = RunWorker(worker, candidate.wasmData, late[@"request"]);
    NSCAssert([Require(app, @{@"op":@"finishCall", @"ticket":late[@"ticket"], @"output":lateOutput})[@"result"]
        isEqual:@"discarded"] && image_session_count(capture) == 0, @"A removed grant rejects delayed output");
    Require(app, @{@"op":@"closeCapture", @"capture":@(capture)});
    NSCAssert(plugin_application_close(app), @"Close after invocation drains");
    app = Open(ReadIndex(path), verified);
    NSCAssert(![Send(app, @{@"op":@"startCall", @"capture":@(capture), @"tool":numbered,
        @"selection":@{@"x":@8, @"y":@12, @"width":@64, @"height":@32}})[@"ok"] boolValue],
              @"Disable survives process restart");
    NSDictionary *remove = Require(app, @{@"op":@"reserveUninstall", @"pluginId":@"com.moojicut.examples.numbered-box"});
    Publish(app, path, remove);
    NSCAssert(plugin_application_close(app), @"Close after removal");
    app = Open(ReadIndex(path), @[]);
    NSCAssert(![Send(app, @{@"op":@"startCall", @"capture":@(capture), @"tool":describe,
        @"selection":NSNull.null})[@"ok"] boolValue], @"Uninstall survives process restart");
    image_session_dispose(capture);
    NSCAssert(plugin_application_close(app), @"Close after replay of removed index");
}

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "Usage: plugin-application worker numbered-box.zip scratch-directory\n");
        return 2;
    }
    @autoreleasepool {
        moonbit_init();
        NSString *worker = [NSString stringWithUTF8String:argv[1]];
        NSURL *zipURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]];
        NSString *root = [[NSString stringWithUTF8String:argv[3]] stringByAppendingPathComponent:@"plugins-v2"];
        CheckInstall(root, worker, zipURL);
        puts("plugin application: real ZIP install, restore, options, removal, numbered box, text, and undo passed");
    }
    return 0;
}
