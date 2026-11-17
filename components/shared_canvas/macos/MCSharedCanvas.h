#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#include "bindings/c/ui_frame.h"

NS_ASSUME_NONNULL_BEGIN

// A platform adapter, not a component implementation. The shared UI supplies
// all drawing, layout, semantics and interaction decisions. Use on the main
// thread; frameDescription is an immutable JSON tree in top-left logical points.
@interface MCSharedCanvasView : NSView
@property (nonatomic, copy, nullable) NSDictionary *frameDescription;
@property (nonatomic, copy, nullable) void (^onEvent)(NSDictionary *event);
@property (nonatomic, copy, nullable) void (^onFrameNeeded)(CGSize size);

// Borrowed producer JSON. The common MoonBit frame boundary validates an
// immutable snapshot before replacing the current frame. Failure preserves it.
// frameDescription remains a lazy debug/fixture view of that same snapshot.
- (BOOL)setFrameJSON:(moonbit_string_t)json;

// Displays native video above the command plane, within videoRect. The media
// surface does not handle input and has no playback controls. The host owns
// playback, media lifetime and its clock; this adapter only presents it.
- (void)setVideoPlayer:(nullable AVPlayer *)player;
@end

NS_ASSUME_NONNULL_END
