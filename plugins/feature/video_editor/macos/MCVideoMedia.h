#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

// Main-thread media port. It owns no views, editor state, drafts or clipboard.
// The host renders player in AVPlayerLayer and supplies MoonBit's edit plan.
@interface MCVideoMedia : NSObject
@property (nonatomic, readonly, copy) NSDictionary *metadata;
@property (nonatomic, readonly) AVPlayer *player;
@property (nonatomic, readonly) double outputDurationMilliseconds;
@property (nonatomic, readonly) double currentOutputMilliseconds;
@property (nonatomic, readonly) BOOL previewingSource;
// Playback only: does not change the authoritative plan or exported duration.
@property (nonatomic, readonly) double previewRate;
// Includes a play request waiting for item readiness/buffering. Use this for
// the transport toggle; player.rate alone is still zero while preparing.
@property (nonatomic, readonly) BOOL playbackRequested;
// A deferred play that fails readiness/capability checks stays paused. Observe
// this property for the failure; successful setPreviewRate/play clears it.
@property (nonatomic, readonly, nullable) NSError *previewPlaybackError;
@property (nonatomic, readonly) BOOL exporting;
@property (nonatomic, readonly) float exportProgress;
- (nullable instancetype)initWithURL:(NSURL *)url error:(NSError **)error;
// Atomic replacement: a rejected plan leaves the current item/position intact.
// Accepts v1 trim/cut plans and single-source v2 plans (90k timebase, 30fps):
// reordered/repeated video (0.25–4x) and explicit independent audio (1–4x).
// Slow audio edits are rejected: the current backend truncates their tail.
// Gaps render black/silent; only v2's audio array supplies sound.
- (BOOL)applyPlan:(NSDictionary *)plan error:(NSError **)error;
// Accepts 0.5, 1, 1.5, 2 or 3 only when the current item is ready and supports
// the requested rate. Rejection leaves the selected rate/playback unchanged.
// Changing a paused preview's rate never starts playback. New items retain the
// selection and recheck capabilities before play; there is no rate fallback.
- (BOOL)setPreviewRate:(double)rate error:(NSError **)error;
// When the item is loading, queues this intent until ready. pause/item changes/
// close cancel it. Playback errors are reported by previewPlaybackError.
- (void)play;
// Terminal main-thread result, including cancellation while waiting for readiness.
- (void)playWithCompletion:(void (^)(NSError * _Nullable error))completion;
- (void)pause;
// Output/composition time. A newer seek, plan or close invalidates older callbacks.
// Only the current request delivers completion, on the main thread.
- (void)seekOutputMilliseconds:(double)milliseconds completion:(nullable void (^)(BOOL finished))completion;
// Orchestrator variant: every accepted request delivers once, even when superseded.
- (void)seekOutputMilliseconds:(double)milliseconds terminal:(void (^)(BOOL finished))completion;
// Temporary source preview, for dragging a trim boundary outside the kept plan.
// The authoritative composition is retained. While previewingSource, the host
// should not use currentOutputMilliseconds to update its composed playhead.
- (void)previewSourceMilliseconds:(double)milliseconds completion:(nullable void (^)(BOOL finished))completion;
- (void)restorePlanPreview;
// Writes a temporary sibling, validates actual media, then publishes atomically.
// Requires applyPlan first. Never modifies the original input file. Completion
// always delivers exactly once, including cancellation and close cleanup.
- (void)exportToURL:(NSURL *)url completion:(void (^)(NSURL * _Nullable, NSError * _Nullable))completion;
- (void)cancelExport;
// Idempotent cancellation. Legacy seek presentation callbacks are suppressed;
// terminal seek/play/export callbacks still acknowledge their resources.
- (void)close;
// Internal lifecycle barrier: waits for seeks/export cleanup and readiness delivery.
// Unlike presentation callbacks, this completion is never suppressed by close.
- (void)closeWithCompletion:(void (^)(void))completion;
@end

NS_ASSUME_NONNULL_END
