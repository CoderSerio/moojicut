#import <AppKit/AppKit.h>

// Sample an underlying scene on a source-pixel grid, then let its host draw the
// returned small image with nearest-neighbour interpolation. No document state.
NSImage *MCPixelatedRegion(NSRect region, CGFloat blockSize, void (^drawUnderlying)(void), NSRect *grid);
