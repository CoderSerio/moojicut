#import <AppKit/AppKit.h>
#import "MCTextRecognitionService.h"

NS_ASSUME_NONNULL_BEGIN
// Host-neutral input: a finalized PNG for the current selection and a lease
// which checks the editor's identity + content snapshot on the main thread. No editor
// implementation dependency, screenshot acquisition, clipboard reads or upload.
@interface MCTextToolsController : NSObject
- (void)openPNGData:(NSData *)data
             owner:(NSString *)owner
      parentWindow:(NSWindow *)window
         isCurrent:(BOOL (^)(void))isCurrent
         translate:(BOOL)translate;
- (void)cancelForOwner:(NSString *)owner;
- (void)cancelAll;
@end
NS_ASSUME_NONNULL_END
