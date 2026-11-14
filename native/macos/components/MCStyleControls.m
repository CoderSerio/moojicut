#import "MCStyleControls.h"
#include "../../shared/editor_style.h"
#include <math.h>

static NSTextField *MCStyleLabel(NSString *text) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:11];
    label.textColor = NSColor.secondaryLabelColor;
    return label;
}
@interface MCNumberControl ()
@property (nonatomic, readwrite) NSTextField *field;
@property (nonatomic, readwrite) NSStepper *stepper;
@end
@implementation MCNumberControl
- (instancetype)initWithLabel:(NSString *)label minimum:(double)minimum maximum:(double)maximum value:(double)value {
    if ((self = [super initWithFrame:NSZeroRect])) {
        self.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        self.alignment = NSLayoutAttributeCenterY;
        self.spacing = 6;
        self.field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 44, 24)];
        self.field.alignment = NSTextAlignmentRight;
        self.field.accessibilityLabel = label;
        self.field.target = self;
        self.field.action = @selector(changed:);
        NSNumberFormatter *formatter = [NSNumberFormatter new];
        formatter.minimum = @(minimum); formatter.maximum = @(maximum);
        formatter.maximumFractionDigits = 1;
        self.field.formatter = formatter;
        self.field.cell.sendsActionOnEndEditing = YES;
        [self.field.widthAnchor constraintEqualToConstant:44].active = YES;
        self.stepper = [NSStepper new];
        self.stepper.minValue = minimum; self.stepper.maxValue = maximum;
        self.stepper.increment = 1; self.stepper.valueWraps = NO;
        self.stepper.target = self; self.stepper.action = @selector(changed:);
        self.stepper.accessibilityLabel = [@"调整" stringByAppendingString:label];
        [self addArrangedSubview:MCStyleLabel(label)];
        [self addArrangedSubview:self.field];
        [self addArrangedSubview:self.stepper];
        self.value = value;
    }
    return self;
}
- (void)setValue:(double)value {
    if (!isfinite(value)) return;
    _value = MAX(self.stepper.minValue, MIN(self.stepper.maxValue, value));
    self.field.doubleValue = self.stepper.doubleValue = _value;
}
- (void)syncFromSender:(id)sender {
    self.value = sender == self.stepper ? self.stepper.doubleValue : self.field.doubleValue;
}
- (void)changed:(id)sender {
    [self syncFromSender:sender];
    if (self.onChange) self.onChange(sender);
}
@end

@interface MCAlphaColorWell : NSColorWell
@end
@implementation MCAlphaColorWell
- (void)activate:(BOOL)exclusive {
    NSColorPanel.sharedColorPanel.showsAlpha = YES;
    [super activate:exclusive];
}
@end
@interface MCColorControl ()
@property (nonatomic, readwrite) NSColorWell *well;
@property (nonatomic, readwrite) MCNumberControl *opacityControl;
@end
@implementation MCColorControl
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        self.alignment = NSLayoutAttributeCenterY;
        self.spacing = 7;
        self.well = [[MCAlphaColorWell alloc] initWithFrame:NSMakeRect(0, 0, 18, 18)];
        self.well.colorWellStyle = NSColorWellStyleMinimal;
        self.well.accessibilityLabel = @"标注颜色与不透明度";
        self.well.toolTip = @"选择颜色和不透明度";
        [self.well.widthAnchor constraintEqualToConstant:18].active = YES;
        [self.well.heightAnchor constraintEqualToConstant:18].active = YES;
        self.well.target = self; self.well.action = @selector(changed:);
        self.opacityControl = [[MCNumberControl alloc] initWithLabel:@"不透明度"
            minimum:editor_style_min(MC_STYLE_OPACITY) * 100 maximum:editor_style_max(MC_STYLE_OPACITY) * 100
            value:editor_style_default(MC_STYLE_OPACITY) * 100];
        self.opacityControl.stepper.increment = editor_style_step(MC_STYLE_OPACITY) * 100;
        [self.opacityControl insertArrangedSubview:MCStyleLabel(@"%") atIndex:2];
        __weak MCColorControl *weakSelf = self;
        self.opacityControl.onChange = ^(id sender) { [weakSelf changed:sender]; };
        [self addArrangedSubview:MCStyleLabel(@"颜色")];
        [self addArrangedSubview:self.well];
        [self addArrangedSubview:self.opacityControl];
        [self setCustomSpacing:16 afterView:self.well];
        int32_t rgb = (int32_t)editor_style_default(MC_STYLE_COLOR);
        self.color = [NSColor colorWithSRGBRed:((rgb >> 16) & 255) / 255.0
            green:((rgb >> 8) & 255) / 255.0 blue:(rgb & 255) / 255.0 alpha:editor_style_default(MC_STYLE_OPACITY)];
    }
    return self;
}
- (NSColor *)color { return self.well.color; }
- (void)setColor:(NSColor *)color {
    NSColor *rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!rgb) return;
    self.well.color = rgb;
    self.opacityControl.value = rgb.alphaComponent * 100;
}
- (void)syncFromSender:(id)sender {
    if (sender == self.opacityControl.field || sender == self.opacityControl.stepper) {
        [self.opacityControl syncFromSender:sender];
        self.well.color = [self.well.color colorWithAlphaComponent:self.opacityControl.value / 100];
    } else {
        self.opacityControl.value = self.well.color.alphaComponent * 100;
    }
}
- (void)changed:(id)sender {
    [self syncFromSender:sender];
    if (self.onChange) self.onChange(sender);
}
@end
