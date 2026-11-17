#import "components/selection/macos/MCSelectionSurface.h"

// Native desktop/window selection. Coordinates are display-local, top-left,
// in points, matching ScreenCaptureKit's sourceRect (never backing pixels).
@interface MCRecordingSelectionView : MCSelectionSurface
@property (copy) NSArray<NSDictionary *> *windowCandidates;
@property NSImage *backdrop;
@property (copy) void (^onConfirm)(NSRect region, NSNumber *windowID, BOOL audio);
@property (copy) void (^onCancel)(void);
@property (copy) void (^onBeginSelection)(void);
@property (readonly) NSRect selection;
@property (readonly) NSNumber *selectedWindowID;
- (void)resetSelection;
@end

@interface MCRecordingCountdownView : NSView
// The shared flow owns phase/timing; this view only renders its panel and
// forwards the action returned by the same shared hit test.
@property (nonatomic) int32_t flowHandle;
@property (copy) void (^onAction)(int32_t action);
- (void)refresh;
@end

@interface MCRecordingOverlayPanel : NSPanel
@end
