#import <AppKit/AppKit.h>
#import "MCSelection.h"

// Shared screenshot/recording input surface. Native events are converted to
// content coordinates here; the geometry itself is implemented by MoonBit.
@interface MCSelectionSurface : NSView
@property (nonatomic, readonly) MCSelectionGesture regionGesture;
@property (nonatomic, readonly) BOOL regionDragging;
- (NSRect)selectionContentFrame;
- (NSSize)selectionContentSize;
- (NSPoint)selectionPointForEvent:(NSEvent *)event;
- (NSRect)selectionViewRect:(NSRect)rect;
- (BOOL)beginRegion:(NSInteger)operation event:(NSEvent *)event rect:(NSRect)rect;
- (void)updateRegion:(NSEvent *)event;
- (BOOL)finishRegion:(NSEvent *)event rect:(NSRect *)rect;
- (void)cancelRegion;
- (void)drawRegion:(NSRect)rect dimensions:(NSSize)pixels handles:(BOOL)handles hint:(NSString *)hint;
@end

@interface MCSelectionWindow : NSWindow
- (void)configureForScreenFrame:(NSRect)frame;
@end

// A global hotkey may still have Command/Shift held while its handler runs.
// Both entry points must wait before presenting a mouse-editable desktop.
void MCSelectionWhenKeysReleased(NSUInteger attempts, BOOL (^isCurrent)(void),
    NSEventModifierFlags (^modifiers)(void), void (^completion)(BOOL released));
