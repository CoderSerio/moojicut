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

// One RGBA value feeds every annotation tool, its swatch and the native panel.
@interface MCColorControl : NSStackView
@property (nonatomic, readonly) NSColorWell *well;
@property (nonatomic, readonly) MCNumberControl *opacityControl;
@property (nonatomic) NSColor *color;
@property (nonatomic, copy, nullable) void (^onChange)(id sender);
- (void)syncFromSender:(id)sender;
@end
NS_ASSUME_NONNULL_END
