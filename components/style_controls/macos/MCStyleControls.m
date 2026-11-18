#import "MCStyleControls.h"
#import "platform/macos/graphics/MCSystemColorPanel.h"
#include "bindings/c/editor_style.h"
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

@implementation MCColorSwatch
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.bordered = NO;
        self.title = @"";
        self.buttonType = NSButtonTypeMomentaryPushIn;
        self.accessibilityElement = YES;
        self.accessibilityRole = NSAccessibilityButtonRole;
        self.color = NSColor.clearColor;
    }
    return self;
}
- (NSSize)intrinsicContentSize {
    CGFloat size = editor_style_swatch_size();
    return NSMakeSize(size, size);
}
- (void)setColor:(NSColor *)color { _color = color; self.needsDisplay = YES; }
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect circle = NSInsetRect(self.bounds, .5, .5);
    NSBezierPath *path = [NSBezierPath bezierPathWithOvalInRect:circle];
    [NSGraphicsContext saveGraphicsState];
    [path addClip];
    // Alpha stays visible, while all painting remains inside the circle.
    for (NSInteger y = 0; y < ceil(NSHeight(self.bounds) / 4); y++)
        for (NSInteger x = 0; x < ceil(NSWidth(self.bounds) / 4); x++) {
            [(x + y) % 2 ? NSColor.lightGrayColor : NSColor.whiteColor setFill];
            NSRectFill(NSMakeRect(x * 4, y * 4, 4, 4));
        }
    [self.color setFill]; [path fill];
    if (!self.enabled || self.highlighted) {
        [[NSColor colorWithWhite:self.enabled ? 0 : 1 alpha:self.enabled ? .12 : .4] setFill];
        [path fill];
    }
    [NSGraphicsContext restoreGraphicsState];
    [NSColor.separatorColor setStroke]; path.lineWidth = 1; [path stroke];
}
- (NSView *)hitTest:(NSPoint)point {
    NSView *hit = [super hitTest:point];
    NSPoint local = [self convertPoint:point fromView:self.superview];
    return hit && [[NSBezierPath bezierPathWithOvalInRect:self.bounds] containsPoint:local] ? hit : nil;
}
- (void)drawFocusRingMask {
    [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(self.bounds, 1, 1)] fill];
}
- (NSRect)focusRingMaskBounds { return self.bounds; }
- (NSString *)accessibilityValue {
    NSColor *rgb = [self.color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    return [NSString stringWithFormat:@"#%02X%02X%02X, %.0f%%", (int)lround(rgb.redComponent * 255),
        (int)lround(rgb.greenComponent * 255), (int)lround(rgb.blueComponent * 255), rgb.alphaComponent * 100];
}
@end
@interface MCColorControl () <NSPopoverDelegate>
@property (nonatomic, readwrite) MCColorSwatch *well;
@property (nonatomic, readwrite) MCNumberControl *opacityControl;
@property (nonatomic, readwrite) NSPopover *popover;
@property NSSlider *opacitySlider;
@property MCSystemColorPanelLease *colorPanelLease;
@end
@implementation MCColorControl
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        self.alignment = NSLayoutAttributeCenterY;
        self.spacing = 7;
        self.well = [[MCColorSwatch alloc] initWithFrame:NSZeroRect];
        self.well.accessibilityLabel = @"标注颜色与不透明度";
        self.well.toolTip = @"选择颜色和不透明度";
        // Size and input bounds are the same shared metric as the drawing.
        for (NSInteger axis = NSLayoutConstraintOrientationHorizontal; axis <= NSLayoutConstraintOrientationVertical; axis++) {
            [self.well setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:axis];
            [self.well setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:axis];
        }
        self.well.target = self; self.well.action = @selector(togglePopover:);
        self.opacityControl = [[MCNumberControl alloc] initWithLabel:@"不透明度"
            minimum:editor_style_min(MC_STYLE_OPACITY) * 100 maximum:editor_style_max(MC_STYLE_OPACITY) * 100
            value:editor_style_default(MC_STYLE_OPACITY) * 100];
        self.opacityControl.stepper.increment = editor_style_step(MC_STYLE_OPACITY) * 100;
        [self.opacityControl insertArrangedSubview:MCStyleLabel(@"%") atIndex:2];
        __weak MCColorControl *weakSelf = self;
        self.opacityControl.onChange = ^(id sender) { [weakSelf changed:sender]; };
        [self addArrangedSubview:MCStyleLabel(@"颜色")];
        [self addArrangedSubview:self.well];
        self.opacitySlider = [NSSlider sliderWithValue:100 minValue:0 maxValue:100 target:self action:@selector(slideOpacity:)];
        self.opacitySlider.continuous = NO; // One completed drag is one style/undo operation.
        self.opacitySlider.accessibilityLabel = @"不透明度";
        [self.opacitySlider.widthAnchor constraintEqualToConstant:72].active = YES;
        NSStackView *swatches = [NSStackView stackViewWithViews:@[]];
        swatches.spacing = 7;
        const int colors[] = {0xef4444,0xf59e0b,0xfacc15,0x22c55e,0x3b82f6,0xa855f7,0xffffff,0x171717};
        NSArray *labels = @[@"红色",@"橙色",@"黄色",@"绿色",@"蓝色",@"紫色",@"白色",@"黑色"];
        for (NSUInteger index = 0; index < 8; index++) {
            MCColorSwatch *swatch = [[MCColorSwatch alloc] initWithFrame:NSZeroRect];
            swatch.color = [NSColor colorWithSRGBRed:((colors[index] >> 16) & 255) / 255.0
                green:((colors[index] >> 8) & 255) / 255.0 blue:(colors[index] & 255) / 255.0 alpha:1];
            swatch.target = self; swatch.action = @selector(chooseSwatch:);
            swatch.accessibilityLabel = labels[index]; swatch.toolTip = labels[index];
            [swatch.widthAnchor constraintEqualToConstant:editor_style_swatch_size()].active = YES;
            [swatch.heightAnchor constraintEqualToConstant:editor_style_swatch_size()].active = YES;
            [swatches addArrangedSubview:swatch];
        }
        NSButton *more = [NSButton buttonWithTitle:@"更多颜色…" target:self action:@selector(showColorPanel:)];
        more.bezelStyle = NSBezelStyleRounded;
        NSStackView *alpha = [NSStackView stackViewWithViews:@[self.opacityControl,self.opacitySlider]];
        alpha.spacing = 10; alpha.alignment = NSLayoutAttributeCenterY;
        NSStackView *content = [NSStackView stackViewWithViews:@[swatches,alpha,more]];
        content.orientation = NSUserInterfaceLayoutOrientationVertical;
        content.alignment = NSLayoutAttributeLeading; content.spacing = 12;
        content.edgeInsets = NSEdgeInsetsMake(14,14,14,14);
        NSViewController *controller = [NSViewController new]; controller.view = content;
        self.popover = [NSPopover new]; self.popover.behavior = NSPopoverBehaviorTransient;
        self.popover.delegate = self; self.popover.contentViewController = controller;
        self.popover.contentSize = NSMakeSize(262,130);
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
    self.opacitySlider.doubleValue = self.opacityControl.value;
    if (self.colorPanelLease.active) [self.colorPanelLease updateColor:rgb];
}
- (void)syncFromSender:(id)sender {
    if (sender == self.opacityControl.field || sender == self.opacityControl.stepper) {
        [self.opacityControl syncFromSender:sender];
        self.well.color = [self.well.color colorWithAlphaComponent:self.opacityControl.value / 100];
    } else {
        self.opacityControl.value = self.well.color.alphaComponent * 100;
    }
    self.opacitySlider.doubleValue = self.opacityControl.value;
}
- (void)togglePopover:(id)sender {
    (void)sender;
    if (self.popover.shown) { [self.popover performClose:nil]; return; }
    self.popover.contentViewController.view.appearance = self.effectiveAppearance;
    [self.popover showRelativeToRect:self.well.bounds ofView:self.well preferredEdge:NSRectEdgeMaxY];
}
- (void)chooseSwatch:(MCColorSwatch *)sender {
    if (![self popoverShouldClose:self.popover]) return;
    self.well.color = [sender.color colorWithAlphaComponent:self.opacityControl.value / 100];
    [self changed:self.well];
}
- (void)slideOpacity:(NSSlider *)sender {
    double value = sender.doubleValue;
    if (![self popoverShouldClose:self.popover]) { sender.doubleValue = self.opacityControl.value; return; }
    self.opacityControl.value = value;
    [self changed:self.opacityControl.field];
}
- (BOOL)popoverShouldClose:(NSPopover *)popover {
    (void)popover;
    NSText *input = self.opacityControl.field.currentEditor;
    if ([input isKindOfClass:NSTextView.class] && [(NSTextView *)input hasMarkedText]) return NO;
    if (input) {
        NSScanner *scanner = [NSScanner scannerWithString:[input.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
        scanner.locale = [(NSNumberFormatter *)self.opacityControl.field.formatter locale];
        double value = 0;
        if (![scanner scanDouble:&value] || !scanner.isAtEnd || !isfinite(value) ||
            value < self.opacityControl.stepper.minValue || value > self.opacityControl.stepper.maxValue) return NO;
    }
    // Native formatter validation and end-editing action keep numeric input in
    // the same transaction path as the property fields on the canvas toolbar.
    return !input || [self.opacityControl.field.window makeFirstResponder:nil];
}
- (void)showColorPanel:(id)sender {
    (void)sender;
    if (![self popoverShouldClose:self.popover]) return;
    [self.popover close];
    self.colorPanelLease = [MCSystemColorPanelLease beginWithOwner:self color:self.color showsAlpha:YES
        onColor:^(MCColorControl *owner, NSColor *color) {
            if (!owner.well.enabled) return;
            owner.color = color;
            [owner changed:owner.well];
        }];
    NSColorPanel *panel = NSColorPanel.sharedColorPanel;
    panel.level = MAX(NSFloatingWindowLevel, self.window.level + 1);
    [panel orderFront:nil];
}
- (void)closePopover {
    [self.popover close];
    BOOL active = self.colorPanelLease.active;
    [self.colorPanelLease invalidate]; self.colorPanelLease = nil;
    if (active && NSColorPanel.sharedColorPanelExists) [NSColorPanel.sharedColorPanel orderOut:nil];
}
- (void)viewWillMoveToWindow:(NSWindow *)window {
    if (self.window && !window) [self closePopover];
    [super viewWillMoveToWindow:window];
}
- (void)dealloc {
    BOOL active = _colorPanelLease.active;
    [_colorPanelLease invalidate];
    if (active && NSColorPanel.sharedColorPanelExists) [NSColorPanel.sharedColorPanel orderOut:nil];
}
- (void)changed:(id)sender {
    [self syncFromSender:sender];
    if (self.onChange) self.onChange(sender);
}
@end
