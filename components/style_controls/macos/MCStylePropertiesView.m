#import "MCStylePropertiesView.h"
#include <math.h>

@interface MCStylePropertiesView ()
@property (nonatomic, readwrite) MCColorControl *colorControl;
@property (nonatomic, readwrite) MCNumberControl *fontControl;
@property (nonatomic, readwrite) MCNumberControl *strokeControl;
@property (nonatomic, readwrite) NSTextField *status;
@end

@implementation MCStylePropertiesView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        self.alignment = NSLayoutAttributeCenterY;
        self.spacing = 18;
        self.detachesHiddenViews = YES;
        self.colorControl = [[MCColorControl alloc] initWithFrame:NSZeroRect];
        self.fontControl = [self numberForProperty:MC_STYLE_FONT label:@"字号"];
        self.strokeControl = [self numberForProperty:MC_STYLE_STROKE label:@"线宽"];
        self.status = [NSTextField labelWithString:@"选择标注以调整属性"];
        self.status.font = [NSFont systemFontOfSize:11];
        self.status.textColor = NSColor.secondaryLabelColor;
        self.status.lineBreakMode = NSLineBreakByTruncatingTail;
        for (NSView *view in @[self.colorControl, self.fontControl, self.strokeControl, self.status])
            [self addArrangedSubview:view];
        __weak MCStylePropertiesView *weakSelf = self;
        void (^changed)(id) = ^(id sender) { if (weakSelf.onChange) weakSelf.onChange(sender); };
        self.colorControl.onChange = changed;
        self.fontControl.onChange = changed;
        self.strokeControl.onChange = changed;
        self.values = (MCStyleValues){(int32_t)editor_style_default(MC_STYLE_COLOR),
            editor_style_default(MC_STYLE_OPACITY), editor_style_default(MC_STYLE_STROKE),
            editor_style_default(MC_STYLE_FONT)};
        self.propertyMask = 0;
    }
    return self;
}
- (MCNumberControl *)numberForProperty:(int32_t)property label:(NSString *)label {
    MCNumberControl *number = [[MCNumberControl alloc] initWithLabel:label
        minimum:editor_style_min(property) maximum:editor_style_max(property) value:editor_style_default(property)];
    number.stepper.increment = editor_style_step(property);
    return number;
}
- (MCStyleValues)values {
    NSColor *color = [self.colorControl.color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    int32_t rgb = ((int32_t)lround(color.redComponent * 255) << 16) |
        ((int32_t)lround(color.greenComponent * 255) << 8) | (int32_t)lround(color.blueComponent * 255);
    return (MCStyleValues){rgb, color.alphaComponent, self.strokeControl.value, self.fontControl.value};
}
- (void)setValues:(MCStyleValues)values {
    self.colorControl.color = [NSColor colorWithSRGBRed:((values.rgb >> 16) & 255) / 255.0
        green:((values.rgb >> 8) & 255) / 255.0 blue:(values.rgb & 255) / 255.0 alpha:values.opacity];
    self.fontControl.value = values.fontSize;
    self.strokeControl.value = values.stroke;
}
- (void)setPropertyMask:(int32_t)mask {
    _propertyMask = mask;
    self.colorControl.hidden = !(mask & (1 << MC_STYLE_COLOR));
    if (self.colorControl.hidden) [self.colorControl closePopover];
    self.fontControl.hidden = !(mask & (1 << MC_STYLE_FONT));
    self.strokeControl.hidden = !(mask & (1 << MC_STYLE_STROKE));
    self.colorControl.well.enabled = !self.colorControl.hidden;
    self.fontControl.field.enabled = self.fontControl.stepper.enabled = !self.fontControl.hidden;
    self.strokeControl.field.enabled = self.strokeControl.stepper.enabled = !self.strokeControl.hidden;
    // No placeholder row when the current tool has no editable properties.
    self.status.hidden = YES;
    self.status.stringValue = @"选择标注以调整属性";
}
- (int32_t)syncFromSender:(id)sender {
    int32_t changed = 0;
    if (!sender || sender == self.fontControl.field || sender == self.fontControl.stepper) {
        [self.fontControl syncFromSender:sender];
        changed |= 1 << MC_STYLE_FONT;
    }
    if (!sender || sender == self.strokeControl.field || sender == self.strokeControl.stepper) {
        [self.strokeControl syncFromSender:sender];
        changed |= 1 << MC_STYLE_STROKE;
    }
    MCNumberControl *opacity = self.colorControl.opacityControl;
    if (!sender || sender == self.colorControl.well || sender == opacity.field || sender == opacity.stepper) {
        [self.colorControl syncFromSender:sender];
        changed |= 1 << MC_STYLE_OPACITY;
        if (!sender || sender == self.colorControl.well) changed |= 1 << MC_STYLE_COLOR;
    }
    return changed & self.propertyMask;
}
- (void)showMessage:(NSString *)message {
    self.propertyMask = 0;
    self.status.stringValue = message;
    self.status.hidden = message.length == 0;
}
@end
