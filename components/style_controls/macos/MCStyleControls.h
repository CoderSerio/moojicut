#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
// The same native numeric interaction is used for font size, stroke and opacity.
@interface MCNumberControl : NSStackView
@property (nonatomic, readonly) NSTextField *field;
@property (nonatomic, readonly) NSStepper *stepper;
@property (nonatomic) double value;
@property (nonatomic, copy, nullable) void (^onChange)(id sender);
- (instancetype)initWithLabel:(NSString *)label minimum:(double)minimum maximum:(double)maximum value:(double)value;
- (void)syncFromSender:(id)sender;
@end

// Draws a circular swatch at the shared UI size; AppKit retains button keyboard
// and accessibility behavior without a system color well's minimum geometry.
@interface MCColorSwatch : NSButton
@property (nonatomic) NSColor *color;
@end

// One RGBA value feeds every annotation tool, its swatch and the native panel.
@interface MCColorControl : NSStackView
@property (nonatomic, readonly) MCColorSwatch *well;
@property (nonatomic, readonly) MCNumberControl *opacityControl;
@property (nonatomic, readonly) NSPopover *popover;
@property (nonatomic) NSColor *color;
@property (nonatomic, copy, nullable) void (^onChange)(id sender);
- (void)syncFromSender:(id)sender;
- (void)closePopover;
@end
NS_ASSUME_NONNULL_END
