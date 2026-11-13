#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>

// kCGWindowBounds uses screen space, with the main display's upper-left corner
// as its origin (CoreGraphics/CGWindow.h). Return logical bounds; the host
// chooses the matching display's backing scale when requesting capture pixels.
int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc != 2 || argv[1][0] < '0' || argv[1][0] > '9') {
      fprintf(stderr, "Expected a positive CGWindowID\n");
      return 1;
    }
    char *end = NULL;
    errno = 0;
    unsigned long long value = strtoull(argv[1], &end, 10);
    if (errno || !end || *end || value == 0 || value > UINT32_MAX) {
      fprintf(stderr, "Invalid CGWindowID\n");
      return 1;
    }
    CGWindowID windowID = (CGWindowID)value;
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, windowID));
    if (!windows) {
      fprintf(stderr, "Window server is unavailable\n");
      return 2;
    }
    for (NSDictionary *window in windows) {
      NSNumber *number = window[(__bridge NSString *)kCGWindowNumber];
      if (!number || number.unsignedLongLongValue != value) continue;
      NSDictionary *dictionary = window[(__bridge NSString *)kCGWindowBounds];
      CGRect bounds;
      if (![dictionary isKindOfClass:NSDictionary.class] ||
          !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)dictionary, &bounds) ||
          !isfinite(bounds.origin.x) || !isfinite(bounds.origin.y) ||
          !isfinite(bounds.size.width) || !isfinite(bounds.size.height) ||
          bounds.size.width <= 0 || bounds.size.height <= 0) {
        fprintf(stderr, "Window bounds are unavailable\n");
        return 3;
      }
      NSDictionary *result = @{ @"x": @(bounds.origin.x), @"y": @(bounds.origin.y),
                                @"w": @(bounds.size.width), @"h": @(bounds.size.height) };
      NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];
      if (!json) return 3;
      fwrite(json.bytes, 1, json.length, stdout);
      fputc('\n', stdout);
      return 0;
    }
    fprintf(stderr, "Window no longer exists or its bounds cannot be read\n");
    return 4;
  }
}
