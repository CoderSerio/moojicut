#import "MCSharedTextInput.h"
#include <math.h>

#define MC_INPUT_HOLD __attribute__((objc_precise_lifetime)) id inputLifetime = self; (void)inputLifetime

static NSString *MCInputString(id value) {
    if ([value isKindOfClass:NSAttributedString.class]) return [value string];
    return [value isKindOfClass:NSString.class] ? value : @"";
}
static NSString *MCInputLF(NSString *value) {
    return [[value stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
        stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
}
static NSUInteger MCInputLFOffset(NSString *value, NSUInteger offset) {
    offset = MIN(offset, value.length);
    // A caret between CR and LF maps to the boundary after the resulting LF.
    NSUInteger removed = 0;
    for (NSUInteger i = 1; i < offset; i++)
        if ([value characterAtIndex:i - 1] == '\r' && [value characterAtIndex:i] == '\n') removed++;
    return offset - removed;
}
static BOOL MCInputRange(NSRange range, NSUInteger length) {
    return range.location != NSNotFound && range.location <= length && range.length <= length - range.location;
}
static NSDictionary *MCInputSelection(NSRange range) {
    return @{ @"kind":@"undirected", @"anchor":@(range.location), @"focus":@(NSMaxRange(range)) };
}
static NSColor *MCInputColor(NSString *hex, double opacity) {
    unsigned rgb = 0;
    if (hex.length == 7 && [hex hasPrefix:@"#"]) {
        NSScanner *scanner = [NSScanner scannerWithString:[hex substringFromIndex:1]];
        if (![scanner scanHexInt:&rgb] || !scanner.isAtEnd) rgb = 0;
    }
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 255) / 255.0
        green:((rgb >> 8) & 255) / 255.0 blue:(rgb & 255) / 255.0 alpha:opacity];
}

@interface MCSharedTextInputView ()
@property (nonatomic, copy, readwrite) NSDictionary *fieldDescription;
@property BOOL retired;
@property NSUInteger applying;
@property NSUInteger explicitInput;
@property NSUInteger callbackDepth;
@property BOOL pendingNative;
@property BOOL resigning;
@property BOOL focusPending;
@property BOOL focusQueued;
@property BOOL applyingFocus;
@property NSUndoManager *sharedUndo;
- (BOOL)sendEdit:(NSDictionary *)edit;
- (void)synchronizeInput;
- (void)queueFocusRequest;
@end

@interface MCSharedInputUndoManager : NSUndoManager
@property (nonatomic, weak) MCSharedTextInputView *input;
@end
@implementation MCSharedInputUndoManager
- (BOOL)canUndo { return !self.input.hasMarkedText && [self.input.fieldDescription[@"canUndo"] boolValue]; }
- (BOOL)canRedo { return !self.input.hasMarkedText && [self.input.fieldDescription[@"canRedo"] boolValue]; }
- (void)undo { [self.input performSharedUndo]; }
- (void)redo { [self.input performSharedRedo]; }
@end

@implementation MCSharedTextInputView
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.richText = NO; self.importsGraphics = NO; self.drawsBackground = NO;
        self.textContainerInset = NSZeroSize; self.textContainer.lineFragmentPadding = 0;
        self.textContainer.widthTracksTextView = YES;
        self.textContainer.heightTracksTextView = NO;
        self.horizontallyResizable = NO; self.verticallyResizable = NO;
        self.allowsUndo = NO;
        self.automaticQuoteSubstitutionEnabled = NO;
        self.automaticDashSubstitutionEnabled = NO;
        self.automaticTextReplacementEnabled = NO;
        MCSharedInputUndoManager *undo = [MCSharedInputUndoManager new];
        undo.input = self; self.sharedUndo = undo;
    }
    return self;
}
- (NSUndoManager *)undoManager { return self.sharedUndo; }
- (NSPoint)textContainerOrigin {
    NSPoint origin = [super textContainerOrigin];
    if (!self.fieldDescription || [self.fieldDescription[@"multiline"] boolValue] || !self.font) return origin;
    // Align single-line ink using the typesetter's baseline, rather than a
    // platform-specific hard-coded top inset. TextKit uses this same origin
    // for drawing, caret/hit testing and IME candidate geometry. No text or
    // selection changes are needed when a shared frame changes size.
    CGFloat baseline = [self.layoutManager defaultBaselineOffsetForFont:self.font];
    CGFloat capHeight = self.font.capHeight;
    CGFloat centered = (NSHeight(self.bounds) + capHeight) / 2 - baseline;
    if (isfinite(centered) && isfinite(capHeight) && capHeight > 0) origin.y = MAX(0, centered);
    return origin;
}
- (BOOL)applyFieldDescription:(NSDictionary *)field {
    if (self.retired || ![field isKindOfClass:NSDictionary.class] ||
        ![field[@"id"] isKindOfClass:NSString.class] || ![field[@"raw"] isKindOfClass:NSString.class] ||
        [field[@"id"] length] == 0 || [field[@"token"] integerValue] <= 0 || [field[@"version"] integerValue] < 0 ||
        [field[@"raw"] rangeOfString:@"\r"].location != NSNotFound) return NO;
    BOOL same = [self.fieldDescription[@"id"] isEqual:field[@"id"]] &&
        [self.fieldDescription[@"token"] isEqual:field[@"token"]];
    if (same && [field[@"version"] integerValue] < [self.fieldDescription[@"version"] integerValue]) return NO;
    BOOL unchanged = same && [field[@"version"] isEqual:self.fieldDescription[@"version"]];
    BOOL focused = [field[@"focused"] boolValue];
    BOOL focusEdge = focused && (!same || ![self.fieldDescription[@"focused"] boolValue]);
    if (!focused || !same) self.focusPending = NO;
    if (focusEdge) self.focusPending = YES;
    self.fieldDescription = [field copy];
    self.applying++;
    double fontSize = [field[@"fontSize"] doubleValue];
    if (!isfinite(fontSize) || fontSize <= 0) fontSize = 13;
    double opacity = field[@"opacity"] ? [field[@"opacity"] doubleValue] : 1;
    if (!isfinite(opacity) || opacity < 0 || opacity > 1) opacity = 1;
    NSString *weight = MCInputString(field[@"weight"]);
    CGFloat fontWeight = [weight isEqual:@"bold"] ? NSFontWeightBold :
        [weight isEqual:@"semibold"] ? NSFontWeightSemibold : [weight isEqual:@"medium"] ? NSFontWeightMedium : NSFontWeightRegular;
    NSFont *font = [NSFont systemFontOfSize:fontSize weight:fontWeight];
    NSColor *color = MCInputColor(MCInputString(field[@"color"]), opacity);
    NSDictionary *attributes = @{NSFontAttributeName:font, NSForegroundColorAttributeName:color};
    if (self.string.length) [self.textStorage addAttributes:attributes range:NSMakeRange(0, self.string.length)];
    self.typingAttributes = attributes;
    self.font = font; self.textColor = color;
    self.insertionPointColor = NSColor.labelColor;
    self.editable = [field[@"enabled"] boolValue] && ![field[@"readOnly"] boolValue];
    self.selectable = [field[@"enabled"] boolValue];
    self.accessibilityIdentifier = field[@"id"];
    self.accessibilityLabel = MCInputString(field[@"label"]);
    self.accessibilityHelp = MCInputString(field[@"error"]).length ? field[@"error"] : MCInputString(field[@"tooltip"]);
    self.toolTip = MCInputString(field[@"tooltip"]);
    if (field[@"x"] && field[@"y"] && field[@"width"] && field[@"height"]) {
        NSRect rect = NSMakeRect([field[@"x"] doubleValue], [field[@"y"] doubleValue],
            [field[@"width"] doubleValue], [field[@"height"] doubleValue]);
        if (isfinite(rect.origin.x) && isfinite(rect.origin.y) && isfinite(rect.size.width) &&
            isfinite(rect.size.height) && rect.size.width >= 0 && rect.size.height >= 0) self.frame = rect;
    }
    self.textContainer.containerSize = NSMakeSize(MAX(1, NSWidth(self.bounds)), CGFLOAT_MAX);
    self.applying--;
    if (!unchanged && !self.explicitInput && !self.pendingNative && !self.callbackDepth) [self synchronizeInput];
    self.needsDisplay = YES;
    [self queueFocusRequest];
    return YES;
}
- (void)queueFocusRequest {
    if (self.retired || !self.focusPending || self.focusQueued || self.applyingFocus || !self.window) return;
    self.focusQueued = YES;
    __weak MCSharedTextInputView *weakSelf = self;
    // Frame installation can be inside the owner's publication guard. Defer the
    // native focus/Select acknowledgement until that synchronous stack finishes.
    dispatch_async(dispatch_get_main_queue(), ^{
        MCSharedTextInputView *input = weakSelf;
        if (!input) return;
        input.focusQueued = NO;
        if (input.retired || !input.window || !input.focusPending ||
            ![input.fieldDescription[@"focused"] boolValue] || ![input.fieldDescription[@"enabled"] boolValue]) return;
        NSResponder *current = input.window.firstResponder;
        if (input.hasMarkedText || ([current isKindOfClass:NSTextView.class] && [(NSTextView *)current hasMarkedText])) return;
        input.focusPending = NO;
        input.applyingFocus = YES;
        if (current != input) [input.window makeFirstResponder:input];
        input.applyingFocus = NO;
    });
}
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self queueFocusRequest];
}
- (void)synchronizeInput {
    if (self.retired || self.applying || self.explicitInput || self.pendingNative || self.callbackDepth || !self.fieldDescription) return;
    NSDictionary *field = self.fieldDescription;
    self.applying++;
    NSString *raw = field[@"raw"];
    BOOL marked = [field[@"marked"] isKindOfClass:NSDictionary.class];
    if (self.hasMarkedText && !marked) [super unmarkText];
    if (![self.string isEqual:raw]) {
        if (self.hasMarkedText) [super unmarkText];
        [super setString:raw];
        if (self.string.length) [self.textStorage addAttributes:self.typingAttributes range:NSMakeRange(0, self.string.length)];
    }
    NSDictionary *selection = field[@"selection"];
    if (![selection isKindOfClass:NSDictionary.class] && [field[@"selectionKnown"] boolValue]) {
        selection = @{ @"kind":@"undirected", @"anchor":field[@"anchor"] ?: @0, @"focus":field[@"focus"] ?: @0 };
    }
    if ([selection isKindOfClass:NSDictionary.class] && ![selection[@"kind"] isEqual:@"unknown"]) {
        NSUInteger anchor = [selection[@"anchor"] unsignedIntegerValue], focus = [selection[@"focus"] unsignedIntegerValue];
        NSRange range = NSMakeRange(MIN(anchor, focus), MAX(anchor, focus) - MIN(anchor, focus));
        if (MCInputRange(range, self.string.length) && !NSEqualRanges(range, self.selectedRange))
            [super setSelectedRange:range];
    }
    self.applying--;
}
- (BOOL)sendEdit:(NSDictionary *)edit {
    BOOL canEdit = self.editable || ([edit[@"type"] isEqual:@"select"] && self.selectable);
    if (self.retired || self.callbackDepth || !canEdit || !self.onEdit || !self.fieldDescription) return NO;
    NSDictionary *before = self.fieldDescription;
    NSDictionary *event = @{ @"type":@"field", @"id":before[@"id"], @"token":before[@"token"],
        @"expectedVersion":before[@"version"], @"edit":edit };
    __attribute__((objc_precise_lifetime)) MCSharedTextInputView *keepAlive = self;
    (void)keepAlive;
    BOOL (^callback)(NSDictionary *) = self.onEdit;
    self.callbackDepth++;
    BOOL accepted = callback(event);
    self.callbackDepth--;
    return accepted && !self.retired && [self.fieldDescription[@"id"] isEqual:before[@"id"]] &&
        [self.fieldDescription[@"token"] isEqual:before[@"token"]] &&
        [self.fieldDescription[@"version"] integerValue] > [before[@"version"] integerValue];
}
- (BOOL)shouldChangeTextInRange:(NSRange)range replacementString:(NSString *)replacement {
    MC_INPUT_HOLD;
    if (self.retired) return NO;
    if (![super shouldChangeTextInRange:range replacementString:replacement]) return NO;
    if (self.applying || self.explicitInput || !replacement) return YES;
    if (!MCInputRange(range, self.string.length) || self.hasMarkedText) return NO;
    NSString *normalized = MCInputLF(replacement);
    // All public insertion/paste paths normalize before this validation point.
    // Refuse an unnormalized lower-level mutation rather than diverging from core.
    if (![replacement isEqual:normalized]) return NO;
    self.pendingNative = YES;
    BOOL accepted = [self sendEdit:@{ @"type":@"replace", @"start":@(range.location), @"end":@(NSMaxRange(range)),
        @"text":replacement, @"selection":MCInputSelection(NSMakeRange(range.location + replacement.length, 0)) }];
    if (!accepted) { self.pendingNative = NO; [self synchronizeInput]; }
    return accepted;
}
- (void)didChangeText {
    MC_INPUT_HOLD;
    self.pendingNative = NO;
    [self synchronizeInput];
    [super didChangeText];
}
- (void)setString:(NSString *)string {
    MC_INPUT_HOLD;
    if (self.applying || !self.fieldDescription) { [super setString:string]; return; }
    if (self.retired || self.hasMarkedText) return;
    NSString *raw = MCInputLF(string);
    if ([self sendEdit:@{ @"type":@"replace", @"start":@0, @"end":@(self.string.length), @"text":raw,
        @"selection":MCInputSelection(NSMakeRange(raw.length,0)) }]) [self synchronizeInput];
}
- (void)setSelectedRanges:(NSArray<NSValue *> *)ranges affinity:(NSSelectionAffinity)affinity stillSelecting:(BOOL)stillSelecting {
    MC_INPUT_HOLD;
    [super setSelectedRanges:ranges affinity:affinity stillSelecting:stillSelecting];
    if (self.retired || self.applying || self.explicitInput || self.pendingNative || self.callbackDepth || !self.fieldDescription) return;
    if (ranges.count != 1 || !MCInputRange(self.selectedRange, self.string.length)) return;
    // AppKit provides an unordered range. Do not invent selection direction.
    [self sendEdit:@{ @"type":@"select", @"selection":MCInputSelection(self.selectedRange) }];
    [self synchronizeInput];
}
- (void)insertText:(id)input replacementRange:(NSRange)replacement {
    MC_INPUT_HOLD;
    if (self.retired || !self.editable) return;
    NSString *text = MCInputLF(MCInputString(input));
    if (!self.hasMarkedText) { [super insertText:text replacementRange:replacement]; return; }
    NSRange marked = self.markedRange;
    if (replacement.location != NSNotFound && !NSEqualRanges(replacement, marked)) return;
    self.explicitInput++;
    BOOL accepted = [self sendEdit:@{ @"type":@"compositionCommit", @"text":text,
        @"selection":MCInputSelection(NSMakeRange(marked.location + text.length,0)) }];
    if (accepted) [super insertText:text replacementRange:marked];
    self.explicitInput--;
    [self synchronizeInput];
}
- (void)setMarkedText:(id)input selectedRange:(NSRange)selection replacementRange:(NSRange)replacement {
    MC_INPUT_HOLD;
    if (self.retired || !self.editable) return;
    NSString *original = MCInputString(input), *text = MCInputLF(original);
    if (!MCInputRange(selection, original.length)) return;
    NSUInteger start = MCInputLFOffset(original, selection.location), end = MCInputLFOffset(original, NSMaxRange(selection));
    NSRange relative = NSMakeRange(start,end-start);
    NSRange marked = self.hasMarkedText ? self.markedRange : self.selectedRange;
    NSRange range = replacement.location == NSNotFound ? marked : replacement;
    if (!MCInputRange(range, self.string.length) || (self.hasMarkedText && !NSEqualRanges(range, marked))) return;
    BOOL began = !self.hasMarkedText;
    NSDictionary *identity = self.fieldDescription;
    self.explicitInput++;
    BOOL accepted = !began || [self sendEdit:@{ @"type":@"compositionStart", @"start":@(range.location),
        @"end":@(NSMaxRange(range)), @"selection":MCInputSelection(range) }];
    if (accepted) accepted = [self sendEdit:@{ @"type":@"compositionUpdate", @"text":text,
        @"selection":MCInputSelection(NSMakeRange(range.location + relative.location, relative.length)) }];
    if (accepted) [super setMarkedText:text selectedRange:relative replacementRange:range];
    else if (began && [identity[@"token"] isEqual:self.fieldDescription[@"token"]] &&
        [identity[@"id"] isEqual:self.fieldDescription[@"id"]])
        [self sendEdit:@{ @"type":@"compositionCancel" }];
    self.explicitInput--;
    [self synchronizeInput];
}
- (void)unmarkText {
    MC_INPUT_HOLD;
    if (self.applying || self.explicitInput || !self.fieldDescription) { [super unmarkText]; return; }
    if (self.retired || !self.hasMarkedText) return;
    NSRange range = self.markedRange;
    if (!MCInputRange(range, self.string.length)) return;
    self.explicitInput++;
    if ([self sendEdit:@{ @"type":@"compositionCommit", @"text":[self.string substringWithRange:range],
        @"selection":MCInputSelection(self.selectedRange) }]) [super unmarkText];
    self.explicitInput--;
    [self synchronizeInput];
}
- (void)performSharedUndo {
    MC_INPUT_HOLD;
    if ([self sendEdit:@{ @"type":@"undo" }]) [self synchronizeInput];
}
- (void)performSharedRedo {
    MC_INPUT_HOLD;
    if ([self sendEdit:@{ @"type":@"redo" }]) [self synchronizeInput];
}
- (void)undo:(__unused id)sender { [self performSharedUndo]; }
- (void)redo:(__unused id)sender { [self performSharedRedo]; }
- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item {
    if (item.action == @selector(undo:)) return self.undoManager.canUndo;
    if (item.action == @selector(redo:)) return self.undoManager.canRedo;
    return [super validateUserInterfaceItem:item];
}
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    MC_INPUT_HOLD;
    if (event.modifierFlags & NSEventModifierFlagCommand) {
        if ([event.charactersIgnoringModifiers.lowercaseString isEqual:@"z"] && !self.hasMarkedText) {
            if (event.modifierFlags & NSEventModifierFlagShift) [self performSharedRedo]; else [self performSharedUndo];
            return YES;
        }
        if (event.keyCode == 36 && !self.hasMarkedText) {
            if (self.onAction) self.onAction(@"commit");
            return YES;
        }
    }
    return [super performKeyEquivalent:event];
}
- (void)keyDown:(NSEvent *)event {
    MC_INPUT_HOLD;
    if (!self.retired && !self.hasMarkedText && ![self.fieldDescription[@"multiline"] boolValue] &&
        (event.keyCode == 126 || event.keyCode == 125) && self.onKey) {
        NSDictionary *identity = self.fieldDescription;
        BOOL (^callback)(NSDictionary *) = self.onKey;
        BOOL handled = callback(@{@"type":@"key",@"key":event.keyCode == 126 ? @"ArrowUp" : @"ArrowDown",
            @"mod":(event.modifierFlags & NSEventModifierFlagCommand) ? @YES : @NO,
            @"shift":(event.modifierFlags & NSEventModifierFlagShift) ? @YES : @NO});
        if (handled || self.retired || ![identity[@"id"] isEqual:self.fieldDescription[@"id"]] ||
            ![identity[@"token"] isEqual:self.fieldDescription[@"token"]]) return;
    }
    if (event.keyCode == 53 && !self.hasMarkedText) { if (self.onAction) self.onAction(@"cancel"); return; }
    [super keyDown:event];
}
- (void)scrollWheel:(NSEvent *)event {
    MC_INPUT_HOLD;
    if (!self.retired && self.editable && !self.hasMarkedText &&
        ![self.fieldDescription[@"multiline"] boolValue] && self.onScroll) {
        NSDictionary *identity = self.fieldDescription;
        BOOL (^callback)(NSEvent *) = self.onScroll;
        BOOL handled = callback(event);
        if (handled || self.retired || ![identity[@"id"] isEqual:self.fieldDescription[@"id"]] ||
            ![identity[@"token"] isEqual:self.fieldDescription[@"token"]]) return;
    }
    [super scrollWheel:event];
}
- (void)insertNewline:(id)sender {
    MC_INPUT_HOLD;
    if (!self.hasMarkedText && ![self.fieldDescription[@"multiline"] boolValue]) {
        if (self.onAction) self.onAction(@"commit");
        return;
    }
    [super insertNewline:sender];
}
- (void)insertTab:(id)sender {
    MC_INPUT_HOLD;
    if (![self.fieldDescription[@"multiline"] boolValue] && !self.hasMarkedText) {
        [self.window selectNextKeyView:sender]; return;
    }
    [super insertTab:sender];
}
- (void)cancelOperation:(__unused id)sender {
    MC_INPUT_HOLD;
    if (self.hasMarkedText) {
        self.explicitInput++;
        if ([self sendEdit:@{ @"type":@"compositionCancel" }]) [super unmarkText];
        self.explicitInput--;
        [self synchronizeInput];
    } else if (self.onAction) self.onAction(@"cancel");
}
- (void)paste:(__unused id)sender {
    NSString *text = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
    if (text) [self insertText:text replacementRange:NSMakeRange(NSNotFound,0)];
}
- (void)pasteAsPlainText:(id)sender { [self paste:sender]; }
- (BOOL)becomeFirstResponder {
    __attribute__((objc_precise_lifetime)) MCSharedTextInputView *keepAlive = self;
    (void)keepAlive;
    BOOL result = [super becomeFirstResponder];
    if (result) self.focusPending = NO;
    // A focus transfer need not change AppKit's selected range. Still publish
    // the observed range so the shared owner can route Undo/Redo to this field.
    // This is an input fact, not a document mutation or inferred caret direction.
    if (result && !self.retired && MCInputRange(self.selectedRange, self.string.length)) {
        [self sendEdit:@{ @"type":@"select", @"selection":MCInputSelection(self.selectedRange) }];
        [self synchronizeInput];
    }
    if (result && !self.retired && self.onAction) self.onAction(@"focus");
    return result && !self.retired;
}
- (BOOL)resignFirstResponder {
    if (self.resigning) return NO;
    __attribute__((objc_precise_lifetime)) MCSharedTextInputView *keepAlive = self;
    (void)keepAlive;
    self.resigning = YES;
    if (!self.retired && self.shouldResign && !self.shouldResign()) { self.resigning = NO; return NO; }
    BOOL result = [super resignFirstResponder];
    if (result && !self.retired && self.onAction) self.onAction(@"blur");
    self.resigning = NO;
    return result;
}
- (NSAccessibilityRole)accessibilityRole {
    return [self.fieldDescription[@"multiline"] boolValue] ? NSAccessibilityTextAreaRole : NSAccessibilityTextFieldRole;
}
- (void)setAccessibilityValue:(id)value {
    MC_INPUT_HOLD;
    if (![value isKindOfClass:NSString.class] || self.retired || self.hasMarkedText) return;
    [self setString:value];
}
- (void)drawRect:(NSRect)dirtyRect {
    [NSGraphicsContext saveGraphicsState];
    NSDictionary *clip = self.fieldDescription[@"clip"];
    if ([clip isKindOfClass:NSDictionary.class]) {
        NSRect rect = NSMakeRect([clip[@"x"] doubleValue] - NSMinX(self.frame),
            [clip[@"y"] doubleValue] - NSMinY(self.frame), [clip[@"width"] doubleValue], [clip[@"height"] doubleValue]);
        NSRectClip(NSIntersectionRect(self.bounds, rect));
    }
    [super drawRect:dirtyRect];
    [NSGraphicsContext restoreGraphicsState];
}
- (void)invalidate {
    self.retired = YES; self.onEdit = nil; self.onAction = nil; self.onKey = nil; self.onScroll = nil; self.shouldResign = nil; self.focusPending = NO;
    self.applying++;
    [super unmarkText];
    self.editable = NO; self.selectable = NO;
    self.applying--;
    self.fieldDescription = nil;
}
@end
