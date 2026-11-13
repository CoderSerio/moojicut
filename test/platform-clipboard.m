#define MOONCAP_PASTEBOARD [NSPasteboard pasteboardWithName:@"dev.mooncap.tests.file-copy"]
#define main clipboardMain
#include "../platform/darwin/clipboard.m"
#undef main
#include <assert.h>

int main(void) {
  @autoreleasepool {
    NSPasteboard *board = MOONCAP_PASTEBOARD;
    NSString *filename = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"mooncap-%@.mp4",NSUUID.UUID.UUIDString]];
    [@"test fixture" writeToFile:filename atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [board clearContents];
    [board setString:@"newer user copy" forType:NSPasteboardTypeString];
    const char *stale[] = {"test", "copy-file", filename.UTF8String, "-1"};
    assert(clipboardMain(4,stale) == 0);
    assert([[board stringForType:NSPasteboardTypeString] isEqualToString:@"newer user copy"]);
    NSString *version = [NSString stringWithFormat:@"%ld",(long)board.changeCount];
    const char *matching[] = {"test", "copy-file", filename.UTF8String, version.UTF8String};
    assert(clipboardMain(4,matching) == 0);
    NSArray *files = [board readObjectsForClasses:@[[NSURL class]] options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}];
    assert(files.count == 1 && [[files[0] path] isEqualToString:filename]);
    assert([board.types containsObject:NSPasteboardTypeFileURL]);
    [board releaseGlobally];
    [[NSFileManager defaultManager] removeItemAtPath:filename error:nil];
    printf("PASS: native file URL pasteboard and newer-copy protection; general clipboard untouched\n");
  }
}
