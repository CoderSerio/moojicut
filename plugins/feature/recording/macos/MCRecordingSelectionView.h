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
@property double remaining;
@property double duration;
@property (copy) void (^onCancel)(void);
@end

@interface MCRecordingOverlayPanel : NSPanel
@end
