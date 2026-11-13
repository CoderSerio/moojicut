#import <AppKit/AppKit.h>

// Production uses the general board. The test binary overrides this macro with
// an isolated named pasteboard, so regression checks never replace a user's copy.
#ifndef MOONCAP_PASTEBOARD
#define MOONCAP_PASTEBOARD NSPasteboard.generalPasteboard
#endif
int main(int argc, const char *argv[]) {
  @autoreleasepool {
    NSPasteboard *board = MOONCAP_PASTEBOARD;
    if (argc == 2 && strcmp(argv[1], "change-count") == 0) {
      printf("%ld\n", (long)board.changeCount);
      return 0;
    }
    if ((argc == 3 || argc == 4) && strcmp(argv[1], "copy-file") == 0) {
      NSString *path = [NSString stringWithUTF8String:argv[2]];
      if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return 2;
      if (argc == 4 && board.changeCount != [[NSString stringWithUTF8String:argv[3]] longLongValue]) { printf("changed\n"); return 0; }
      [board clearContents];
      if (![board writeObjects:@[[NSURL fileURLWithPath:path]]]) return 3;
      printf("%ld\n", (long)board.changeCount);
      return 0;
    }
    fprintf(stderr, "Expected change-count or copy-file PATH\n");
    return 1;
  }
}
