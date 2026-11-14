#import "MCImageEditorController.h"
#include "moonbit.h"
#include <math.h>

extern moonbit_string_t image_create(moonbit_string_t);
extern moonbit_string_t image_apply(moonbit_string_t);
extern moonbit_string_t image_finalize(moonbit_string_t);

static NSError *MCEditorError(NSString *message) {
    return [NSError errorWithDomain:@"dev.moojicut.image-editor" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
static NSDictionary *MCCallImage(moonbit_string_t (*function)(moonbit_string_t), NSDictionary *request, NSError **error) {
    NSData *bytes = [NSJSONSerialization dataWithJSONObject:request options:0 error:error];
    if (!bytes) return nil;
    NSString *json = [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
    if (json.length > INT32_MAX) { if (error) *error = MCEditorError(@"标注内容过大。"); return nil; }
    moonbit_string_t input = moonbit_make_string_raw((int32_t)json.length);
    [json getCharacters:input range:NSMakeRange(0, json.length)];
    moonbit_string_t output = function(input);
    moonbit_decref(input);
    NSString *text = [[NSString alloc] initWithCharacters:output length:(NSUInteger)Moonbit_array_length(output)];
    moonbit_decref(output);
    id value = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:error];
    if (![value isKindOfClass:NSDictionary.class] || ![value[@"ok"] boolValue]) {
        if (error) *error = MCEditorError([value isKindOfClass:NSDictionary.class] ? (value[@"error"][@"message"] ?: @"MoonBit 无法应用标注。") : @"无法读取编辑结果。");
        return nil;
    }
    return value[@"document"];
}
static NSColor *MCAnnotationColor(NSDictionary *annotation) {
    unsigned int rgb = 0;
    NSString *hex = annotation[@"color"] ?: @"#ef4444";
    if (hex.length == 7) [[NSScanner scannerWithString:[hex substringFromIndex:1]] scanHexInt:&rgb];
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 255) / 255.0 green:((rgb >> 8) & 255) / 255.0
                              blue:(rgb & 255) / 255.0 alpha:[annotation[@"opacity"] doubleValue]];
}
static void MCDrawAnnotation(NSDictionary *annotation) {
    NSString *kind = annotation[@"type"];
    NSRect rect = NSMakeRect([annotation[@"x"] doubleValue], [annotation[@"y"] doubleValue],
                             [annotation[@"width"] doubleValue], [annotation[@"height"] doubleValue]);
    NSColor *color = MCAnnotationColor(annotation);
    CGFloat stroke = [annotation[@"stroke"] doubleValue];
    if ([kind isEqualToString:@"redact"]) {
        // A cover is always solid black and is rendered after every other annotation.
        [NSColor.blackColor setFill];
        NSRectFill(rect);
    } else if ([kind isEqualToString:@"rect"]) {
        [color setStroke];
        NSBezierPath *path = [NSBezierPath bezierPathWithRect:rect];
        path.lineWidth = stroke;
        [path stroke];
    } else if ([kind isEqualToString:@"arrow"]) {
        NSPoint start = rect.origin, end = NSMakePoint([annotation[@"x2"] doubleValue], [annotation[@"y2"] doubleValue]);
        CGFloat angle = atan2(end.y - start.y, end.x - start.x);
        CGFloat head = MIN(hypot(end.x - start.x, end.y - start.y) * 0.45, MAX(14, stroke * 3.5));
        NSBezierPath *path = [NSBezierPath bezierPath];
        path.lineWidth = stroke;
        path.lineCapStyle = NSLineCapStyleRound;
        path.lineJoinStyle = NSLineJoinStyleRound;
        [path moveToPoint:start]; [path lineToPoint:end];
        [path moveToPoint:NSMakePoint(end.x - head * cos(angle - 0.5), end.y - head * sin(angle - 0.5))];
        [path lineToPoint:end];
        [path lineToPoint:NSMakePoint(end.x - head * cos(angle + 0.5), end.y - head * sin(angle + 0.5))];
        [color setStroke]; [path stroke];
    } else if ([kind isEqualToString:@"text"]) {
        NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
        paragraph.lineBreakMode = NSLineBreakByWordWrapping;
        [annotation[@"text"] drawInRect:rect withAttributes:@{
            NSFontAttributeName:[NSFont systemFontOfSize:[annotation[@"fontSize"] doubleValue] weight:NSFontWeightSemibold],
            NSForegroundColorAttributeName:color, NSParagraphStyleAttributeName:paragraph }];
    }
}
static void MCDrawImage(NSImage *image, NSDictionary *document, NSDictionary *pending) {
    NSRect rect = NSMakeRect(0, 0, [document[@"width"] doubleValue], [document[@"height"] doubleValue]);
    [NSGraphicsContext saveGraphicsState];
    NSRectClip(rect);
    [image drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1 respectFlipped:YES hints:nil];
    NSArray *annotations = document[@"annotations"];
    for (NSDictionary *annotation in annotations) if (![annotation[@"type"] isEqualToString:@"redact"]) MCDrawAnnotation(annotation);
    if (pending && ![pending[@"type"] isEqualToString:@"redact"]) MCDrawAnnotation(pending);
    for (NSDictionary *annotation in annotations) if ([annotation[@"type"] isEqualToString:@"redact"]) MCDrawAnnotation(annotation);
    if ([pending[@"type"] isEqualToString:@"redact"]) MCDrawAnnotation(pending);
    [NSGraphicsContext restoreGraphicsState];
}

@class MCImageCanvas;
@interface MCImageEditorController ()
@property (nonatomic, readwrite) NSWindow *window;
@property (nonatomic, readwrite) NSDictionary *document;
@property NSImage *image;
@property MCImageCanvas *canvas;
@property NSSegmentedControl *tools;
@property NSColorWell *color;
@property NSButton *undoButton;
@property NSButton *redoButton;
@property NSTextField *status;
- (void)chooseTool:(id)sender;
- (NSDictionary *)annotationFrom:(NSPoint)start to:(NSPoint)end;
- (void)addTextAtPoint:(NSPoint)point;
- (void)confirm:(id)sender;
@end

@interface MCImageCanvas : NSView
@property (weak) MCImageEditorController *editor;
@property NSPoint start;
@property NSDictionary *pending;
@property BOOL dragging;
- (NSRect)imageFrame;
@end
@implementation MCImageCanvas
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (NSRect)imageFrame {
    CGFloat width = [self.editor.document[@"width"] doubleValue], height = [self.editor.document[@"height"] doubleValue];
    CGFloat scale = MIN((self.bounds.size.width - 32) / width, (self.bounds.size.height - 32) / height);
    scale = MAX(0.01, scale);
    return NSMakeRect((self.bounds.size.width - width * scale) / 2, (self.bounds.size.height - height * scale) / 2, width * scale, height * scale);
}
- (NSPoint)imagePoint:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSRect frame = [self imageFrame];
    CGFloat scale = frame.size.width / [self.editor.document[@"width"] doubleValue];
    return NSMakePoint(MAX(0, MIN([self.editor.document[@"width"] doubleValue], (point.x - frame.origin.x) / scale)),
                       MAX(0, MIN([self.editor.document[@"height"] doubleValue], (point.y - frame.origin.y) / scale)));
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [NSColor.underPageBackgroundColor setFill]; NSRectFill(self.bounds);
    NSRect frame = [self imageFrame];
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *transform = [NSAffineTransform transform];
    [transform translateXBy:frame.origin.x yBy:frame.origin.y];
    [transform scaleBy:frame.size.width / [self.editor.document[@"width"] doubleValue]];
    [transform concat];
    MCDrawImage(self.editor.image, self.editor.document, self.pending);
    [NSGraphicsContext restoreGraphicsState];
}
- (void)mouseDown:(NSEvent *)event {
    [self.window makeFirstResponder:self];
    if (!NSPointInRect([self convertPoint:event.locationInWindow fromView:nil], [self imageFrame])) return;
    self.start = [self imagePoint:event];
    if (self.editor.tools.selectedSegment == 2) { [self.editor addTextAtPoint:self.start]; return; }
    self.dragging = YES;
}
- (void)mouseDragged:(NSEvent *)event {
    if (!self.dragging) return;
    self.pending = [self.editor annotationFrom:self.start to:[self imagePoint:event]];
    self.needsDisplay = YES;
}
- (void)mouseUp:(NSEvent *)event {
    if (!self.dragging) return;
    self.dragging = NO;
    NSDictionary *annotation = [self.editor annotationFrom:self.start to:[self imagePoint:event]];
    self.pending = nil;
    if (annotation) [self.editor applyAnnotation:annotation];
    self.needsDisplay = YES;
}
- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == 53) {
        if (self.dragging) { self.dragging = NO; self.pending = nil; self.needsDisplay = YES; }
        else [self.editor cancel:nil];
    } else [super keyDown:event];
}
@end

@implementation MCImageEditorController
- (instancetype)initWithPNGData:(NSData *)data error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:data];
    if (!bitmap || bitmap.pixelsWide < 1 || bitmap.pixelsHigh < 1 || bitmap.pixelsWide > 32768 || bitmap.pixelsHigh > 32768 ||
        bitmap.pixelsWide * bitmap.pixelsHigh > 80000000) {
        if (error) *error = MCEditorError(@"截图无法读取，或图片尺寸过大。");
        return nil;
    }
    _document = MCCallImage(image_create, @{@"width":@(bitmap.pixelsWide), @"height":@(bitmap.pixelsHigh)}, error);
    if (!_document) return nil;
    _image = [[NSImage alloc] initWithSize:NSMakeSize(bitmap.pixelsWide, bitmap.pixelsHigh)];
    [_image addRepresentation:bitmap];
    return self;
}
- (NSButton *)button:(NSString *)title action:(SEL)action key:(NSString *)key {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    button.bezelStyle = NSBezelStyleRounded;
    if (key) button.keyEquivalent = key;
    return button;
}
- (void)show {
    if (!self.window) {
        NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
        CGFloat width = MIN(1100, screen.visibleFrame.size.width - 80), height = MIN(760, screen.visibleFrame.size.height - 100);
        self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, width, height)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
        self.window.releasedWhenClosed = NO;
        self.window.delegate = self;
        self.window.title = @"Mooji Cut · 标注截图";
        self.window.minSize = NSMakeSize(700, 400);
        NSView *root = self.window.contentView;
        self.canvas = [[MCImageCanvas alloc] initWithFrame:NSMakeRect(0, 48, width, height - 108)];
        self.canvas.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        self.canvas.editor = self;
        self.canvas.accessibilityLabel = @"截图标注画布";
        [root addSubview:self.canvas];
        self.tools = [NSSegmentedControl segmentedControlWithLabels:@[@"矩形", @"箭头", @"文字", @"遮挡"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(chooseTool:)];
        self.tools.selectedSegment = 0;
        self.tools.accessibilityLabel = @"标注工具";
        self.color = [[NSColorWell alloc] initWithFrame:NSMakeRect(0, 0, 42, 28)];
        self.color.color = [NSColor colorWithSRGBRed:0.94 green:0.27 blue:0.27 alpha:1];
        self.color.accessibilityLabel = @"标注颜色";
        self.color.colorWellStyle = NSColorWellStyleMinimal;
        self.undoButton = [self button:@"撤销" action:@selector(undo:) key:@"z"];
        self.redoButton = [self button:@"重做" action:@selector(redo:) key:@"z"];
        self.undoButton.keyEquivalentModifierMask = NSEventModifierFlagCommand;
        self.redoButton.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
        NSStackView *toolbar = [NSStackView stackViewWithViews:@[self.tools, self.color, self.undoButton, self.redoButton]];
        toolbar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        toolbar.spacing = 12;
        toolbar.frame = NSMakeRect(18, height - 48, width - 36, 32);
        toolbar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
        [root addSubview:toolbar];
        self.status = [NSTextField labelWithString:@""];
        self.status.frame = NSMakeRect(18, 15, width - 300, 20);
        self.status.autoresizingMask = NSViewWidthSizable;
        self.status.textColor = NSColor.secondaryLabelColor;
        [root addSubview:self.status];
        NSButton *cancel = [self button:@"取消" action:@selector(cancel:) key:@"\e"];
        cancel.keyEquivalentModifierMask = 0;
        cancel.frame = NSMakeRect(width - 240, 9, 86, 32);
        cancel.autoresizingMask = NSViewMinXMargin;
        [root addSubview:cancel];
        NSButton *confirm = [self button:@"确认并复制" action:@selector(confirm:) key:@"\r"];
        confirm.keyEquivalentModifierMask = 0;
        confirm.frame = NSMakeRect(width - 150, 9, 132, 32);
        confirm.autoresizingMask = NSViewMinXMargin;
        [root addSubview:confirm];
        [self.window center];
    }
    [self refresh];
    [NSApp unhide:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self.canvas];
}
- (void)refresh {
    self.undoButton.enabled = [self.document[@"undo"] count] > 0;
    self.redoButton.enabled = [self.document[@"redo"] count] > 0;
    self.canvas.needsDisplay = YES;
    self.status.stringValue = [NSString stringWithFormat:@"%@ × %@ 像素 · %lu 条标注", self.document[@"width"], self.document[@"height"], (unsigned long)[self.document[@"annotations"] count]];
}
- (void)showError:(NSError *)error {
    self.status.stringValue = error.localizedDescription;
    NSBeep();
}
- (NSString *)colorHex {
    NSColor *color = [self.color.color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    return [NSString stringWithFormat:@"#%02x%02x%02x", (unsigned)lround(color.redComponent * 255),
        (unsigned)lround(color.greenComponent * 255), (unsigned)lround(color.blueComponent * 255)];
}
- (void)chooseTool:(id)sender {
    (void)sender;
    self.canvas.dragging = NO; self.canvas.pending = nil; self.canvas.needsDisplay = YES;
    self.color.enabled = self.tools.selectedSegment != 3;
    self.status.stringValue = self.tools.selectedSegment == 2 ? @"点击画面添加文字。" :
        self.tools.selectedSegment == 3 ? @"拖动画面添加不透明遮挡。" : @"在画面上拖动添加标注。";
}
- (NSDictionary *)annotationFrom:(NSPoint)start to:(NSPoint)end {
    if (hypot(end.x - start.x, end.y - start.y) < 3) return nil;
    BOOL arrow = self.tools.selectedSegment == 1, redact = self.tools.selectedSegment == 3;
    if (!arrow && (fabs(end.x - start.x) < 2 || fabs(end.y - start.y) < 2)) return nil;
    NSMutableDictionary *annotation = [@{
        @"id":NSUUID.UUID.UUIDString, @"type":arrow ? @"arrow" : redact ? @"redact" : @"rect",
        @"x":@(arrow ? start.x : MIN(start.x,end.x)), @"y":@(arrow ? start.y : MIN(start.y,end.y)),
        @"width":@(MAX(1,fabs(end.x-start.x))), @"height":@(MAX(1,fabs(end.y-start.y))),
        @"stroke":@4, @"opacity":@1, @"color":redact ? @"#000000" : [self colorHex] } mutableCopy];
    if (arrow) { annotation[@"x2"] = @(end.x); annotation[@"y2"] = @(end.y); }
    return annotation;
}
- (void)addTextAtPoint:(NSPoint)point {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"添加文字";
    alert.informativeText = @"输入需要标注的内容。";
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 340, 28)];
    field.placeholderString = @"输入文字";
    alert.accessoryView = field;
    [alert addButtonWithTitle:@"添加"]; [alert addButtonWithTitle:@"取消"];
    __weak MCImageEditorController *weakSelf = self;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        MCImageEditorController *owner = weakSelf;
        if (!owner || response != NSAlertFirstButtonReturn || field.stringValue.length == 0) return;
        CGFloat size = 28, imageWidth = [owner.document[@"width"] doubleValue], imageHeight = [owner.document[@"height"] doubleValue];
        NSSize measured = [field.stringValue sizeWithAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:size weight:NSFontWeightSemibold]}];
        [owner applyAnnotation:@{ @"id":NSUUID.UUID.UUIDString, @"type":@"text", @"text":field.stringValue,
            @"x":@(MIN(point.x,imageWidth-1)), @"y":@(MIN(point.y,imageHeight-1)), @"width":@(MAX(1,MIN(measured.width+10,imageWidth-point.x))),
            @"height":@(MAX(1,MIN(MAX(42,measured.height*2),imageHeight-point.y))), @"fontSize":@(size), @"stroke":@3, @"opacity":@1, @"color":[owner colorHex] }];
        [owner.window makeFirstResponder:owner.canvas];
    }];
    [self.window.attachedSheet makeFirstResponder:field];
}
- (BOOL)applyCommand:(NSDictionary *)command {
    NSError *error = nil;
    NSDictionary *document = MCCallImage(image_apply, @{@"document":self.document, @"expectedRevision":self.document[@"revision"], @"command":command}, &error);
    if (!document) { [self showError:error]; return NO; }
    self.document = document;
    [self refresh];
    return YES;
}
- (BOOL)applyAnnotation:(NSDictionary *)annotation { return [self applyCommand:@{@"type":@"add", @"annotations":@[annotation]}]; }
- (void)undo:(id)sender { (void)sender; [self applyCommand:@{@"type":@"undo"}]; }
- (void)redo:(id)sender { (void)sender; [self applyCommand:@{@"type":@"redo"}]; }
- (NSData *)renderPNGData:(NSError **)error {
    NSDictionary *finalized = MCCallImage(image_finalize, @{@"document":self.document}, error);
    if (!finalized) return nil;
    NSInteger width = [finalized[@"width"] integerValue], height = [finalized[@"height"] integerValue];
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:width*4 bitsPerPixel:32];
    if (!bitmap) { if (error) *error = MCEditorError(@"内存不足，无法生成截图。"); return nil; }
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    if (!context) { if (error) *error = MCEditorError(@"无法创建图片画布。"); return nil; }
    [NSGraphicsContext saveGraphicsState];
    CGContextRef cg = context.CGContext;
    CGContextTranslateCTM(cg, 0, height);
    CGContextScaleCTM(cg, 1, -1);
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithCGContext:cg flipped:YES]];
    MCDrawImage(self.image, finalized, nil);
    [NSGraphicsContext restoreGraphicsState];
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (!png && error) *error = MCEditorError(@"无法编码 PNG 图片。");
    return png;
}
- (BOOL)copyToPasteboard:(NSPasteboard *)pasteboard error:(NSError **)error {
    NSData *png = [self renderPNGData:error];
    if (!png) return NO;
    NSPasteboardItem *item = [NSPasteboardItem new];
    [item setData:png forType:NSPasteboardTypePNG];
    // TIFF is also provided for applications whose image paste support predates PNG.
    NSData *tiff = [[NSImage alloc] initWithData:png].TIFFRepresentation;
    if (tiff) [item setData:tiff forType:NSPasteboardTypeTIFF];
    [pasteboard clearContents];
    BOOL written = [pasteboard writeObjects:@[item]];
    if (!written && error) *error = MCEditorError(@"图片未能写入剪贴板，请重试。");
    return written;
}
- (void)confirm:(id)sender {
    (void)sender;
    if (self.canvas.dragging || self.window.attachedSheet) return;
    NSError *error = nil;
    if ([self copyToPasteboard:NSPasteboard.generalPasteboard error:&error]) [self.window close];
    else [self showError:error];
}
- (void)cancel:(id)sender { (void)sender; [self.window close]; }
- (void)windowWillClose:(NSNotification *)notification {
    (void)notification;
    void (^closed)(void) = self.onClose;
    self.onClose = nil;
    self.window.delegate = nil;
    self.window.contentView = nil;
    self.window = nil;
    self.canvas = nil;
    [self.color deactivate];
    [NSColorPanel.sharedColorPanel orderOut:nil];
    if (closed) closed();
}
+ (BOOL)runSmokeInDirectory:(NSString *)directory error:(NSError **)error {
    NSBitmapImageRep *sample = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:320 pixelsHigh:200
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:1280 bitsPerPixel:32];
    for (NSInteger y=0; y<200; y++) for (NSInteger x=0; x<320; x++) {
        unsigned char *pixel = sample.bitmapData + y * sample.bytesPerRow + x * 4;
        pixel[0] = pixel[1] = y < 100 ? 255 : 0;
        pixel[2] = pixel[3] = 255;
    }
    NSData *png = [sample representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    MCImageEditorController *editor = [[self alloc] initWithPNGData:png error:error];
    if (!editor) return NO;
    [editor show];
    NSArray *annotations = @[
        @{@"id":@"rect",@"type":@"rect",@"x":@20,@"y":@20,@"width":@100,@"height":@50,@"stroke":@4,@"opacity":@1,@"color":@"#ff0000"},
        @{@"id":@"arrow",@"type":@"arrow",@"x":@140,@"y":@30,@"x2":@240,@"y2":@70,@"stroke":@4,@"opacity":@1,@"color":@"#00aa00"},
        @{@"id":@"text",@"type":@"text",@"x":@20,@"y":@125,@"width":@200,@"height":@45,@"text":@"中文标注 ✅",@"fontSize":@24,@"stroke":@3,@"opacity":@1,@"color":@"#ffffff"},
        @{@"id":@"mask",@"type":@"redact",@"x":@250,@"y":@130,@"width":@50,@"height":@45,@"stroke":@3,@"opacity":@1,@"color":@"#000000"}
    ];
    BOOL passed = YES;
    for (NSDictionary *annotation in annotations) passed = [editor applyAnnotation:annotation] && passed;
    [editor undo:nil]; passed = passed && [editor.document[@"annotations"] count] == 3;
    [editor redo:nil]; passed = passed && [editor.document[@"annotations"] count] == 4;
    NSData *rendered = [editor renderPNGData:error];
    NSBitmapImageRep *result = rendered ? [NSBitmapImageRep imageRepWithData:rendered] : nil;
    NSColor *top = [[result colorAtX:5 y:5] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    NSColor *bottom = [[result colorAtX:5 y:195] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    NSColor *cover = [[result colorAtX:275 y:150] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    passed = passed && result.pixelsWide == 320 && result.pixelsHigh == 200 && top.redComponent > 0.9 &&
        bottom.blueComponent > 0.9 && bottom.redComponent < 0.1 && cover.redComponent < 0.05 && cover.alphaComponent > 0.99;
    NSPasteboard *pasteboard = [NSPasteboard pasteboardWithUniqueName];
    passed = [editor copyToPasteboard:pasteboard error:error] && passed;
    passed = passed && [pasteboard dataForType:NSPasteboardTypePNG].length > 0;
    [pasteboard releaseGlobally];
    if (rendered && directory.length) {
        [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
        passed = [rendered writeToFile:[directory stringByAppendingPathComponent:@"annotated.png"] atomically:YES] && passed;
        NSView *content = editor.window.contentView;
        [content layoutSubtreeIfNeeded];
        [editor.window displayIfNeeded];
        NSBitmapImageRep *preview = [content bitmapImageRepForCachingDisplayInRect:content.bounds];
        [content cacheDisplayInRect:content.bounds toBitmapImageRep:preview];
        [[preview representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
            writeToFile:[directory stringByAppendingPathComponent:@"editor.png"] atomically:YES];
    }
    [editor cancel:nil];
    passed = passed && editor.window == nil;
    if (!passed && error && !*error) *error = MCEditorError(@"截图编辑器验证未通过。");
    return passed;
}
@end
