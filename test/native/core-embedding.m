#import <Foundation/Foundation.h>
#include <assert.h>
#include "moonbit.h"
#include "native/shared/editor_style.h"
#include "native/shared/update_release.h"
#include "native/shared/plugin_protocol.h"

// Signatures observed in native foreign_library output from moonc 0.10.20.
// This test deliberately checks the real boundary instead of a mocked core.
extern moonbit_string_t image_create(moonbit_string_t request);
extern moonbit_string_t image_apply(moonbit_string_t request);
extern moonbit_string_t image_finalize(moonbit_string_t request);
extern moonbit_string_t video_open(moonbit_string_t source, moonbit_string_t draft);
extern moonbit_string_t video_command(int32_t session, moonbit_string_t command);
extern moonbit_string_t video_seek(int32_t session, double milliseconds);
extern moonbit_string_t video_snapshot(int32_t session);
extern int32_t video_dispose(int32_t session);

// UTF-16 code units, not UTF-8 bytes. Inputs stay caller-owned; outputs are
// copied into Foundation before releasing their MoonBit reference.
static moonbit_string_t MoonString(NSString *text) {
  NSCAssert(text.length <= INT32_MAX, @"Input too large");
  moonbit_string_t value = moonbit_make_string_raw((int32_t)text.length);
  [text getCharacters:value range:NSMakeRange(0, text.length)];
  return value;
}
static NSString *JSONText(id value) {
  NSError *error = nil;
  NSData *bytes = [NSJSONSerialization dataWithJSONObject:value options:0 error:&error];
  NSCAssert(bytes && !error, @"JSON input: %@", error);
  return [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
}
static NSDictionary *TakeJSON(moonbit_string_t value) {
  NSString *text = [[NSString alloc] initWithCharacters:value length:(NSUInteger)Moonbit_array_length(value)];
  moonbit_decref(value);
  NSError *error = nil;
  NSDictionary *result = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:&error];
  NSCAssert(result && !error, @"JSON output: %@, %@", text, error);
  return result;
}
static NSDictionary *Call(moonbit_string_t (*function)(moonbit_string_t), NSDictionary *request) {
  moonbit_string_t argument = MoonString(JSONText(request));
  int32_t references = Moonbit_rc_count(Moonbit_object_header(argument));
  moonbit_string_t result = function(argument);
  NSCAssert(Moonbit_rc_count(Moonbit_object_header(argument)) == references, @"Inputs remain caller-owned");
  moonbit_decref(argument);
  return TakeJSON(result);
}
static NSDictionary *EditImage(NSDictionary *document, NSDictionary *command) {
  NSDictionary *result = Call(image_apply, @{ @"document":document, @"command":command, @"expectedRevision":document[@"revision"] });
  NSCAssert([result[@"ok"] boolValue], @"Image command failed: %@", result);
  return result[@"document"];
}
static NSDictionary *EditVideo(int32_t session, NSDictionary *command) {
  moonbit_string_t input = MoonString(JSONText(command));
  moonbit_string_t output = video_command(session, input);
  NSCAssert(Moonbit_rc_count(Moonbit_object_header(input)) == 1, @"Video input ownership");
  moonbit_decref(input);
  NSDictionary *result = TakeJSON(output);
  NSCAssert([result[@"ok"] boolValue], @"Video command failed: %@", result);
  return result;
}
static void CheckEditorStyles(void) {
  NSCAssert(editor_style_property_mask(MC_STYLE_TOOL_TEXT) ==
            ((1 << MC_STYLE_COLOR) | (1 << MC_STYLE_OPACITY) | (1 << MC_STYLE_FONT)), @"Style capabilities cross the C boundary");
  NSCAssert(editor_style_min(MC_STYLE_STROKE) == 1 && editor_style_max(MC_STYLE_STROKE) == 96 &&
            editor_style_step(MC_STYLE_STROKE) == 1 && editor_style_default(MC_STYLE_STROKE) == 4, @"Style domain exports");
  int32_t first = editor_style_create();
  int32_t second = editor_style_create();
  NSCAssert(first > 0 && second > 0 && first != second, @"Independent style handles");
  NSCAssert(editor_style_set(first, MC_STYLE_TOOL_RECTANGLE, MC_STYLE_STROKE, 2.5) == 1 &&
            editor_style_get(first, MC_STYLE_TOOL_RECTANGLE, MC_STYLE_STROKE) == 2.5, @"Fractional styles roundtrip through C");
  NSCAssert(editor_style_get(first, MC_STYLE_TOOL_ARROW, MC_STYLE_STROKE) == 4 &&
            editor_style_get(second, MC_STYLE_TOOL_RECTANGLE, MC_STYLE_STROKE) == 4, @"Styles stay isolated per tool and editor");
  editor_style_dispose(first);
  NSCAssert(editor_style_get(first, MC_STYLE_TOOL_RECTANGLE, MC_STYLE_STROKE) == 0 &&
            editor_style_set(first, MC_STYLE_TOOL_RECTANGLE, MC_STYLE_STROKE, 8) == 0, @"Disposed style handles reject access");
  NSCAssert(editor_style_get(second, MC_STYLE_TOOL_RECTANGLE, MC_STYLE_STROKE) == 4 &&
            editor_style_set(second, MC_STYLE_TOOL_RECTANGLE, MC_STYLE_STROKE, 6.5) == 1 &&
            editor_style_get(second, MC_STYLE_TOOL_RECTANGLE, MC_STYLE_STROKE) == 6.5, @"Disposal leaves the other editor usable");
  editor_style_dispose(second);
}
static void CheckPluginUTF16Boundary(void) {
  moonbit_string_t (*functions[])(moonbit_string_t) = {
    plugin_manifest_validate, plugin_request_prepare, plugin_output_validate, tool_registry_resolve,
  };
  // Construct raw C ABI input: NSString/UTF-8 decoding normally rejects these
  // sequences before they reach MoonBit, so a host-side JSON test is insufficient.
  const uint16_t invalid[][4] = {
    {0xd800}, {0xdc00}, {0xdbff}, {0xdfff},
    {0xd800, 'A'}, {'A', 0xdc00}, {0xd800, 0xd800}, {0xdc00, 0xd800},
    {0xd800, 0xdc00, 0xd800}, {0xdbff, 0xdfff, 0xdc00},
  };
  const int32_t lengths[] = {1,1,1,1,2,2,2,2,3,3};
  for (NSUInteger function = 0; function < sizeof(functions)/sizeof(functions[0]); function++) {
    for (NSUInteger sample = 0; sample < sizeof(lengths)/sizeof(lengths[0]); sample++) {
      // Wrap each malformed sequence inside JSON text so rejection cannot rely
      // on an unrelated syntax error. The Unicode check precedes field parsing.
      const uint16_t prefix[] = {'{','"','x','"',':','"'};
      int32_t count = (int32_t)(sizeof(prefix)/sizeof(prefix[0])) + lengths[sample] + 2;
      moonbit_string_t input = moonbit_make_string_raw(count);
      memcpy(input, prefix, sizeof(prefix));
      memcpy(input + 6, invalid[sample], (size_t)lengths[sample] * sizeof(uint16_t));
      input[count-2] = '"'; input[count-1] = '}';
      NSDictionary *result = TakeJSON(functions[function](input));
      NSCAssert(Moonbit_rc_count(Moonbit_object_header(input)) == 1, @"Invalid plugin input stays caller-owned");
      moonbit_decref(input);
      NSCAssert(![result[@"ok"] boolValue] && [result[@"error"][@"code"] isEqual:@"invalid_json"],
                @"Malformed UTF-16 must return invalid_json through every plugin export: %@", result);
    }
  }
  NSString *unicode = @"中文🦊\uD7FF\uE000";
  NSDictionary *manifest = @{@"apiVersion":@1,@"pluginId":@"com.example.unicode",@"name":unicode,@"version":@"1.0.0",
    @"entry":@"plugin.wasm",@"runtime":@"extism-1",@"capabilities":@[@"capture.metadata",@"result.text"],
    @"tools":@[@{@"toolId":@"text",@"title":unicode,@"target":@"screenshot",@"action":@"run"}]};
  NSDictionary *validated = Call(plugin_manifest_validate, manifest);
  NSCAssert([validated[@"ok"] boolValue] && [validated[@"manifest"][@"name"] isEqual:unicode], @"Valid UTF-16 survives manifest validation");
  NSDictionary *request = Call(plugin_request_prepare, @{@"manifest":manifest,@"toolId":@"user.com.example.unicode/text",
    @"invocationId":@"utf16-test",@"capture":@{@"width":@320,@"height":@180,@"format":@"png",@"revision":@0}});
  NSCAssert([request[@"ok"] boolValue], @"Valid surrogate pairs also survive request preparation");
  NSDictionary *result = Call(plugin_output_validate, @{@"invocationId":@"utf16-test",@"output":@{
    @"apiVersion":@1,@"invocationId":@"utf16-test",@"kind":@"text",@"title":unicode,@"text":unicode}});
  NSCAssert([result[@"ok"] boolValue] && [result[@"result"][@"text"] isEqual:unicode], @"Plugin result Unicode roundtrips without replacement");
  NSCAssert([Call(tool_registry_resolve, @{@"layout":NSNull.null,@"manifests":@[manifest]})[@"ok"] boolValue],
            @"Dynamic tool catalog accepts the same valid Unicode manifest");
}
int main(void) {
  @autoreleasepool {
    moonbit_init(); // Once per process, before allocations or exported calls.
    CheckEditorStyles();
    CheckPluginUTF16Boundary();
    moonbit_string_t unicode = MoonString(@"中文🦊");
    assert(Moonbit_array_length(unicode) == 4);
    assert(unicode[0] == 0x4e2d && unicode[1] == 0x6587 && unicode[2] == 0xd83e && unicode[3] == 0xdd8a);
    moonbit_decref(unicode);

    // Verify the real exported ownership boundary, not a mock C parser. Repeated
    // checks release both caller-owned inputs and the short-lived result handle.
    for (int i = 0; i < 64; i++) {
      NSString *version = @"0.1.0-alpha.10";
      NSString *name = [@"moojicut-" stringByAppendingString:[version stringByAppendingString:@"-macos-arm64.zip"]];
      NSString *prefix = [@"https://github.com/CoderSerio/moojicut/releases/download/v" stringByAppendingString:[version stringByAppendingString:@"/"]];
      NSString *response = JSONText(@[@{@"tag_name":[@"v" stringByAppendingString:version], @"draft":@NO,
        @"prerelease":@YES, @"published_at":@"2026-11-15T00:00:00Z",
        @"html_url":[@"https://github.com/CoderSerio/moojicut/releases/tag/v" stringByAppendingString:version],
        @"assets":@[@{@"name":name, @"state":@"uploaded", @"size":@1234,
          @"browser_download_url":[prefix stringByAppendingString:name],
          @"digest":@"sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}]}]);
      moonbit_string_t current = MoonString(@"0.1.0-alpha.9"), body = MoonString(response);
      int handle = update_release_create(current, MC_UPDATE_MACOS_ARM64, body);
      assert(Moonbit_rc_count(Moonbit_object_header(current)) == 1);
      assert(Moonbit_rc_count(Moonbit_object_header(body)) == 1);
      moonbit_decref(current); moonbit_decref(body);
      assert(handle > 0 && update_release_status(handle) == MC_UPDATE_AVAILABLE && update_release_size(handle) == 1234);
      moonbit_string_t selected = update_release_text(handle, MC_UPDATE_VERSION);
      update_release_dispose(handle);
      NSString *selectedVersion = [[NSString alloc] initWithCharacters:selected length:(NSUInteger)Moonbit_array_length(selected)];
      moonbit_decref(selected);
      assert([selectedVersion isEqual:version] && update_release_status(handle) == MC_UPDATE_INVALID);
    }

    NSDictionary *created = Call(image_create, @{ @"width":@640, @"height":@360 });
    NSCAssert([created[@"ok"] boolValue], @"Create failed");
    NSString *text = @"中文截图 🦊\n第二行";
    NSDictionary *annotation = @{ @"id":@"中文标注-🦊", @"type":@"text", @"x":@80, @"y":@70, @"width":@250, @"height":@80, @"text":text, @"fontSize":@24, @"color":@"#16a085" };
    NSDictionary *document = EditImage(created[@"document"], @{ @"type":@"add", @"annotations":@[annotation] });
    NSCAssert([document[@"annotations"][0][@"text"] isEqualToString:text], @"Unicode annotation roundtrip");
    NSDictionary *conflict = Call(image_apply, @{ @"document":document, @"command":@{ @"type":@"undo" }, @"expectedRevision":@0 });
    NSCAssert(![conflict[@"ok"] boolValue] && [conflict[@"error"][@"code"] isEqualToString:@"revision_conflict"], @"Stale edits are rejected across the bridge");
    document = EditImage(document, @{ @"type":@"crop", @"rect":@{ @"x":@40, @"y":@30, @"width":@400, @"height":@250 } });
    NSDictionary *finalized = Call(image_finalize, @{ @"document":document });
    NSCAssert([finalized[@"ok"] boolValue], @"Finalize failed");
    document = finalized[@"document"];
    NSCAssert([document[@"width"] intValue] == 400 && [document[@"annotations"][0][@"x"] intValue] == 40, @"Crop rebases vectors");
    NSCAssert([document[@"annotations"][0][@"text"] isEqualToString:text], @"Unicode survives finalize");

    moonbit_string_t source = MoonString(JSONText(@{ @"durationMs":@6000, @"width":@640, @"height":@360, @"hasAudio":@YES }));
    moonbit_string_t empty = MoonString(@"");
    NSDictionary *opened = TakeJSON(video_open(source, empty));
    assert(Moonbit_rc_count(Moonbit_object_header(source)) == 1);
    assert(Moonbit_rc_count(Moonbit_object_header(empty)) == 1);
    moonbit_decref(source); moonbit_decref(empty);
    NSCAssert([opened[@"ok"] boolValue], @"Open video failed");
    int32_t session = [opened[@"session"] intValue];
    EditVideo(session, @{ @"type":@"cut", @"cut":@{ @"startMs":@1000, @"endMs":@2000 } });
    NSDictionary *video = EditVideo(session, @{ @"type":@"cut", @"cut":@{ @"startMs":@3000, @"endMs":@4000 } });
    NSCAssert([video[@"plan"][@"outputDurationMs"] intValue] == 4000 && [video[@"plan"][@"segments"] count] == 3, @"Multiple cuts");
    video = EditVideo(session, @{ @"type":@"undo" });
    NSCAssert([video[@"plan"][@"outputDurationMs"] intValue] == 5000, @"Undo cut");
    video = EditVideo(session, @{ @"type":@"redo" });
    NSCAssert([video[@"plan"][@"outputDurationMs"] intValue] == 4000, @"Redo cut");
    video = EditVideo(session, @{ @"type":@"crop", @"crop":@{ @"x":@10, @"y":@10, @"width":@401, @"height":@201 } });
    NSCAssert([video[@"document"][@"crop"][@"width"] intValue] == 400 && [video[@"document"][@"crop"][@"height"] intValue] == 200, @"Even crop");
    video = EditVideo(session, @{ @"type":@"mute", @"muted":@YES });
    NSCAssert([video[@"document"][@"muted"] boolValue], @"Mute");
    NSCAssert([video[@"plan"][@"profile"][@"audioBitrateKbps"] intValue] == 0, @"Mute reaches the export plan");
    NSDictionary *seek = TakeJSON(video_seek(session, 1500));
    NSCAssert([seek[@"sourceMs"] intValue] == 2000 && [seek[@"outputMs"] intValue] == 1000, @"Preview skips deleted interval");
    (void)video_dispose(session);
    NSDictionary *closed = TakeJSON(video_snapshot(session));
    NSCAssert(![closed[@"ok"] boolValue] && [closed[@"error"][@"message"] isEqualToString:@"视频编辑会话已关闭"], @"Chinese error roundtrip");

    for (int i = 0; i < 1000; i++) { @autoreleasepool {
      NSDictionary *result = Call(image_create, @{ @"width":@640, @"height":@360 });
      NSCAssert([result[@"ok"] boolValue], @"Repeated bridge invocation");
    } }
    puts("PASS native embedding: plugin UTF-16 rejection/Unicode roundtrip, ownership, 1000 calls, editor style ABI/isolation, image revisions/finalize, video edits/preview/dispose");
  }
  return 0;
}
