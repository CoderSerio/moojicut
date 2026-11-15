#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

// A platform adapter, not a component implementation. The shared UI supplies
// all drawing, layout, semantics and interaction decisions. Use on the main
// thread; frameDescription is an immutable JSON tree in top-left logical points.
@interface MCSharedCanvasView : NSView
@property (nonatomic, copy, nullable) NSDictionary *frameDescription;
@property (nonatomic, copy, nullable) void (^onEvent)(NSDictionary *event);
@property (nonatomic, copy, nullable) void (^onFrameNeeded)(CGSize size);

// Displays native video above the command plane, within videoRect. The media
// surface does not handle input and has no playback controls. The host owns
// playback, media lifetime and its clock; this adapter only presents it.
- (void)setVideoPlayer:(nullable AVPlayer *)player;
@end

NS_ASSUME_NONNULL_END
