#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

// One frozen desktop image per display, shared by screenshot and recording
// selection. The overlay is not shown until all images are ready.
void MCDesktopSnapshot(SCDisplay *display, NSArray<SCRunningApplication *> *excluded,
    NSArray<SCWindow *> *included, void (^completion)(NSData *png, NSError *error));
