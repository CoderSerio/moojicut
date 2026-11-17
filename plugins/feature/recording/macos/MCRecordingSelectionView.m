#import "MCRecordingSelectionView.h"
#include "bindings/c/recording_flow.h"
#import "components/selection/macos/MCSelection.h"
#include <math.h>

@implementation MCRecordingOverlayPanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface MCRecordingSelectionView ()
@property (readwrite) NSRect selection;
@property (readwrite) NSNumber *selectedWindowID;
@property NSRect hoverRect;
@property NSNumber *hoverWindowID;
@property BOOL selected, dragging, includesAudio;
@property NSPoint anchor;
@property NSVisualEffectView *controls;
@property NSButton *audioButton;
@end

@implementation MCRecordingSelectionView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.controls = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0,0,180,44)];
        self.controls.material = NSVisualEffectMaterialHUDWindow; self.controls.state = NSVisualEffectStateActive;
        self.controls.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        self.controls.wantsLayer = YES; self.controls.layer.cornerRadius = 12; self.controls.layer.masksToBounds = YES;
        self.controls.hidden = YES; [self addSubview:self.controls];
        self.audioButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"speaker.wave.2.fill" accessibilityDescription:@"系统声音"] target:self action:@selector(toggleAudio:)];
        self.audioButton.frame = NSMakeRect(6,6,32,32); self.audioButton.bordered = NO; self.audioButton.contentTintColor = NSColor.whiteColor;
        self.includesAudio = YES; [self updateAudio];
        [self.controls addSubview:self.audioButton];
        NSButton *start = [NSButton buttonWithTitle:@"录制" image:[NSImage imageWithSystemSymbolName:@"record.circle" accessibilityDescription:nil] target:self action:@selector(confirm:)];
        start.frame = NSMakeRect(44,6,90,32); start.bordered = NO; start.contentTintColor = NSColor.whiteColor;
        start.keyEquivalent = @"\r"; [self.controls addSubview:start];
        start.toolTip = @"开始录制（Enter）；倒计时期间可以取消";
        NSButton *cancel = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"xmark" accessibilityDescription:@"取消录屏"] target:self action:@selector(cancel:)];
        cancel.frame = NSMakeRect(140,6,32,32); cancel.bordered = NO; cancel.contentTintColor = NSColor.whiteColor; cancel.keyEquivalent = @"\e";
        cancel.toolTip = @"取消 (Esc)"; [self.controls addSubview:cancel];
        [self setAccessibilityLabel:@"拖拽框选，单击选择窗口，回车开始录制，Esc 取消"];
        self.toolTip = @"拖动框选录屏范围，或单击选择窗口；拖动边框移动选区，拖动圆点调整大小";
    }
    return self;
}
- (BOOL)isOpaque { return YES; }
- (void)updateTrackingAreas {
    for (NSTrackingArea *area in self.trackingAreas.copy) [self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil]];
    [super updateTrackingAreas];
}
- (void)resetCursorRects {
    [self addCursorRect:self.bounds cursor:NSCursor.crosshairCursor];
    if (!self.controls.hidden) [self addCursorRect:self.controls.frame cursor:NSCursor.arrowCursor];
}
- (void)updateAudio {
    BOOL enabled = self.includesAudio;
    self.audioButton.image = [NSImage imageWithSystemSymbolName:enabled ? @"speaker.wave.2.fill" : @"speaker.slash.fill" accessibilityDescription:@"系统声音"];
    self.audioButton.toolTip = enabled ? @"录制系统声音：已开启，点击关闭" : @"录制系统声音：已关闭，点击开启";
    [self.audioButton setAccessibilityValue:enabled ? @"开" : @"关"];
}
- (void)toggleAudio:(__unused id)sender {
    self.includesAudio = !self.includesAudio;
    [self updateAudio];
}
- (void)confirm:(__unused id)sender {
    if (self.selected && self.selection.size.width >= 2 && self.selection.size.height >= 2 && self.onConfirm)
        self.onConfirm(self.selection, self.selectedWindowID, self.includesAudio);
}
- (void)cancel:(__unused id)sender { if (self.onCancel) self.onCancel(); }
- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == 53) [self cancel:nil];
    else if (event.keyCode == 36 || event.keyCode == 76) [self confirm:nil];
    else [super keyDown:event];
}
- (void)resetSelection {
    self.selected = NO; self.selectedWindowID = nil; self.selection = NSZeroRect;
    self.hoverRect = NSZeroRect; self.hoverWindowID = nil; self.controls.hidden = YES;
    self.needsDisplay = YES; [self.window invalidateCursorRectsForView:self];
}
- (void)updateHover:(NSPoint)point {
    self.hoverRect = self.bounds; self.hoverWindowID = nil;
    for (NSDictionary *candidate in self.windowCandidates) {
        NSRect rect = [candidate[@"rect"] rectValue];
        if (NSPointInRect(point, rect)) { self.hoverRect = rect; self.hoverWindowID = candidate[@"windowID"]; break; }
    }
    self.needsDisplay = YES;
}
- (void)mouseEntered:(NSEvent *)event { [self.window makeKeyWindow]; [self.window makeFirstResponder:self]; [self mouseMoved:event]; }
- (void)mouseExited:(__unused NSEvent *)event { if (!self.selected) { self.hoverRect = NSZeroRect; self.needsDisplay = YES; } }
- (void)mouseMoved:(NSEvent *)event { if (!self.selected) [self updateHover:[self convertPoint:event.locationInWindow fromView:nil]]; }
- (void)mouseDown:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    [self.window makeFirstResponder:self];
    if (self.onBeginSelection) self.onBeginSelection();
    self.anchor = point; self.dragging = NO;
    NSInteger operation = self.selected ? MCSelectionHitTest(YES,self.selection,self.selection,point,point) : MCSelectionNone;
    if (operation == MCSelectionNone) operation = MCSelectionCreate;
    [self beginRegion:operation event:event rect:self.selection];
    if (operation == MCSelectionCreate) { [self resetSelection]; [self updateHover:point]; }
}
- (void)mouseDragged:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (!self.dragging && hypot(point.x-self.anchor.x,point.y-self.anchor.y) < 3) return;
    self.dragging = YES; self.selectedWindowID = nil;
    [self updateRegion:event];
    self.selection = self.regionGesture.preview; self.selected = YES; self.controls.hidden = YES; self.needsDisplay = YES;
}
- (void)mouseUp:(NSEvent *)event {
    if (self.dragging) {
        NSRect rect = self.selection;
        self.selected = [self finishRegion:event rect:&rect]; self.selection = rect;
    } else if (!self.selected) {
        self.selection = self.hoverRect; self.selectedWindowID = self.hoverWindowID; self.selected = !NSIsEmptyRect(self.selection);
    }
    self.dragging = NO; [self cancelRegion];
    if (self.selected) {
        CGFloat x = MAX(6,MIN(NSMaxX(self.selection)-180,self.bounds.size.width-186));
        CGFloat y = NSMaxY(self.selection)+8;
        if (y+44 > NSMaxY(self.bounds)-6) y = MAX(6,NSMaxY(self.selection)-52);
        self.controls.frame = NSMakeRect(x,y,180,44); self.controls.hidden = NO;
    }
    self.needsDisplay = YES; [self.window invalidateCursorRectsForView:self];
}
- (void)drawRect:(__unused NSRect)dirtyRect {
    // Like screenshot selection, the whole surface contains frozen pixels.
    // A transparent hover/selection hole must never expose the window beneath
    // as a competing mouse target.
    [NSColor.blackColor setFill]; NSRectFill(self.bounds);
    [self.backdrop drawInRect:self.bounds fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    NSRect rect = self.selected ? self.selection : self.hoverRect;
    CGFloat scale = self.backdrop.size.width > 0 ? self.backdrop.size.width/NSWidth(self.bounds) : 1;
    [self drawRegion:rect dimensions:NSMakeSize(rect.size.width*scale,rect.size.height*scale)
        handles:self.selected hint:@"拖动框选录屏范围 · Esc 取消"];
}
@end

@interface MCRecordingCountdownView ()
@property NSButton *actionButton;
@end
@implementation MCRecordingCountdownView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self=[super initWithFrame:frame])) {
        self.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        self.actionButton=[NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"xmark" accessibilityDescription:@"取消录屏"]
            target:self action:@selector(performAction:)];
        self.actionButton.bordered=NO; self.actionButton.contentTintColor=NSColor.whiteColor;
        self.actionButton.keyEquivalent=@"\e";
        [self addSubview:self.actionButton];
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (void)setFlowHandle:(int32_t)handle { _flowHandle=handle; [self refresh]; }
- (void)setFrameSize:(NSSize)size { [super setFrameSize:size]; [self refresh]; }
- (void)refresh {
    double *frame=recording_ui_frame(self.flowHandle,NSWidth(self.bounds),NSHeight(self.bounds));
    self.actionButton.frame=NSMakeRect(frame[8],frame[9],frame[10],frame[11]);
    self.actionButton.hidden=frame[13]==0;
    BOOL cancel=(int32_t)frame[13]==MC_RECORDING_CANCEL;
    NSString *label=cancel ? @"取消录屏" : @"停止录屏";
    self.actionButton.image=[NSImage imageWithSystemSymbolName:cancel ? @"xmark" : @"stop.fill" accessibilityDescription:label];
    self.actionButton.toolTip=[label stringByAppendingString:@"（Esc）"];
    [self.actionButton setAccessibilityLabel:label];
    moonbit_decref(frame); self.needsDisplay=YES;
}
- (void)performAction:(__unused id)sender {
    NSRect button=self.actionButton.frame;
    int32_t action=recording_ui_hit(self.flowHandle,NSMidX(button),NSMidY(button),NSWidth(self.bounds),NSHeight(self.bounds));
    if (action && self.onAction) self.onAction(action);
}
- (void)mouseUp:(NSEvent *)event {
    NSPoint point=[self convertPoint:event.locationInWindow fromView:nil];
    int32_t action=recording_ui_hit(self.flowHandle,point.x,point.y,NSWidth(self.bounds),NSHeight(self.bounds));
    if (action && self.onAction) self.onAction(action);
}
- (void)keyDown:(NSEvent *)event {
    if (event.keyCode==53) [self performAction:nil]; else [super keyDown:event];
}
- (void)drawRect:(__unused NSRect)dirtyRect {
    double *frame=recording_ui_frame(self.flowHandle,NSWidth(self.bounds),NSHeight(self.bounds));
    if (frame[2]<=0 || frame[3]<=0) { moonbit_decref(frame); return; }
    [[NSColor colorWithWhite:0.09 alpha:0.94] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(frame[0],frame[1],frame[2],frame[3]) xRadius:20 yRadius:20] fill];
    moonbit_string_t value=recording_ui_text(self.flowHandle);
    NSString *text=[[NSString alloc] initWithCharacters:value length:Moonbit_array_length(value)]; moonbit_decref(value);
    NSMutableParagraphStyle *paragraph=[NSMutableParagraphStyle new]; paragraph.alignment=NSTextAlignmentCenter;
    NSDictionary *attributes=@{NSFontAttributeName:[NSFont monospacedDigitSystemFontOfSize:frame[12] weight:NSFontWeightMedium],
        NSForegroundColorAttributeName:NSColor.whiteColor,NSParagraphStyleAttributeName:paragraph};
    NSSize size=[text sizeWithAttributes:attributes];
    NSRect rect=NSMakeRect(frame[4],frame[5]+MAX(0,(frame[7]-size.height)/2),frame[6],MIN(size.height,frame[7]));
    [text drawInRect:rect withAttributes:attributes]; moonbit_decref(frame);
}
@end
