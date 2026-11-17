#import "MCStylePropertiesView.h"
#import "components/icons/macos/MCIcon.h"
#include <math.h>

@interface MCStylePropertiesView ()
@property (nonatomic, readwrite) MCColorControl *colorControl;
@property (nonatomic, readwrite) MCNumberControl *fontControl;
@property (nonatomic, readwrite) MCNumberControl *strokeControl;
@property (nonatomic, readwrite) NSSegmentedControl *shapeControl;
@property (nonatomic) NSStackView *shapeGroup;
@property (nonatomic, readwrite) MCNumberControl *blockControl;
@property (nonatomic, readwrite) NSTextField *status;
@end

@implementation MCStylePropertiesView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        self.alignment = NSLayoutAttributeCenterY;
        self.distribution = NSStackViewDistributionGravityAreas;
        self.spacing = editor_style_group_gap();
        self.detachesHiddenViews = YES;
        self.colorControl = [[MCColorControl alloc] initWithFrame:NSZeroRect];
        self.fontControl = [self numberForProperty:MC_STYLE_FONT label:@"字号"];
        self.strokeControl = [self numberForProperty:MC_STYLE_STROKE label:@"线宽"];
        self.blockControl = [self numberForProperty:MC_STYLE_BLOCK label:@"颗粒"];
        ((NSNumberFormatter *)self.blockControl.field.formatter).maximumFractionDigits = 0;
        self.shapeControl = [NSSegmentedControl segmentedControlWithLabels:@[@"",@""]
            trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(shapeChanged:)];
        self.shapeControl.segmentStyle = NSSegmentStyleSeparated;
        self.shapeControl.controlSize = NSControlSizeSmall;
        self.shapeControl.accessibilityLabel = @"形状";
        NSTextField *shapeLabel = [NSTextField labelWithString:@"形状"];
        shapeLabel.font = [NSFont systemFontOfSize:11];
        shapeLabel.textColor = NSColor.secondaryLabelColor;
        self.shapeGroup = [NSStackView stackViewWithViews:@[shapeLabel, self.shapeControl]];
        self.shapeGroup.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        self.shapeGroup.alignment = NSLayoutAttributeCenterY;
        self.shapeGroup.spacing = 4;
        self.status = [NSTextField labelWithString:@"选择标注以调整属性"];
        self.status.font = [NSFont systemFontOfSize:11];
        self.status.textColor = NSColor.secondaryLabelColor;
        self.status.lineBreakMode = NSLineBreakByTruncatingTail;
        for (NSView *view in @[self.shapeGroup, self.colorControl, self.fontControl, self.strokeControl, self.blockControl, self.status]) {
            [view setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
            [self addView:view inGravity:NSStackViewGravityLeading];
        }
        __weak MCStylePropertiesView *weakSelf = self;
        void (^changed)(id) = ^(id sender) { if (weakSelf.onChange) weakSelf.onChange(sender); };
        self.colorControl.onChange = changed;
        self.fontControl.onChange = changed;
        self.strokeControl.onChange = changed;
        self.blockControl.onChange = changed;
        self.values = (MCStyleValues){(int32_t)editor_style_default(MC_STYLE_COLOR),
            editor_style_default(MC_STYLE_OPACITY), editor_style_default(MC_STYLE_STROKE),
            editor_style_default(MC_STYLE_FONT)};
        self.propertyMask = 0;
    }
    return self;
}
- (void)shapeChanged:(id)sender { if (self.onChange) self.onChange(sender); }
- (void)configureForTool:(int32_t)tool shape:(int32_t)shape {
    NSInteger count = editor_style_shape_count(tool);
    if (count) {
        self.shapeControl.segmentCount = count;
        const MCIcon outline[] = {MC_ICON_RECTANGLE, MC_ICON_ELLIPSE};
        const MCIcon cover[] = {MC_ICON_REDACT, MC_ICON_COVER_ELLIPSE, MC_ICON_MOSAIC};
        NSArray *labels = @[@"方框",@"圆框",@"马赛克"];
        for (NSInteger index = 0; index < count; index++) {
            [self.shapeControl setImage:MCIconImage(tool == MC_STYLE_TOOL_COVER ? cover[index] : outline[index], labels[index]) forSegment:index];
            [self.shapeControl setToolTip:labels[index] forSegment:index];
            [self.shapeControl setWidth:26 forSegment:index];
        }
        self.shapeControl.selectedSegment = MAX(0, MIN(count-1, shape));
    }
    self.propertyMask = editor_style_visible_mask(tool, shape);
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
    self.shapeControl.hidden = self.shapeGroup.hidden = !(mask & (1 << MC_STYLE_SHAPE));
    self.blockControl.hidden = !(mask & (1 << MC_STYLE_BLOCK));
    self.colorControl.well.enabled = !self.colorControl.hidden;
    self.fontControl.field.enabled = self.fontControl.stepper.enabled = !self.fontControl.hidden;
    self.strokeControl.field.enabled = self.strokeControl.stepper.enabled = !self.strokeControl.hidden;
    self.shapeControl.enabled = !self.shapeControl.hidden;
    self.blockControl.field.enabled = self.blockControl.stepper.enabled = !self.blockControl.hidden;
    // No placeholder row when the current tool has no editable properties.
    self.status.hidden = YES;
    self.status.stringValue = @"选择标注以调整属性";
}
- (int32_t)syncFromSender:(id)sender {
    int32_t changed = 0;
    if (sender == self.shapeControl) changed |= 1 << MC_STYLE_SHAPE;
    if (sender == self.blockControl.field || sender == self.blockControl.stepper) {
        [self.blockControl syncFromSender:sender]; changed |= 1 << MC_STYLE_BLOCK;
    }
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
