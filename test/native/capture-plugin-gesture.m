#import <AppKit/AppKit.h>
#import "plugins/feature/image_editor/macos/MCImageEditorController.h"
#import "plugins/feature/capture/macos/MCCaptureController.h"
#include "bindings/c/capture_edit.h"
#include "bindings/c/capture_toolbar.h"
#include "bindings/c/image_session.h"
#include "bindings/c/tool_registry.h"
#import "capture-toolbar-fixture.h"

// Hidden synthetic windows. Deliver actual view mouse events without injecting
// system input, requesting capture permission, or touching the clipboard.
@interface MCImageCanvas : NSView
@property (readonly) NSRect imageFrame;
@property (readonly) NSDictionary *pending;
@property (readonly) BOOL dragging;
- (void)cancelGesture;
@end
@interface MCImageEditorController (MCPluginGestureFixture)
@property (readonly) MCImageCanvas *canvas;
@property (readonly) MCSharedCanvasView *toolbar;
@property (readonly) int32_t imageSession;
@property (readonly) int32_t toolbarHandle;
- (BOOL)setCaptureRegion:(NSRect)rect;
@end
@interface MCCaptureController (MCPluginGestureFixture)
- (MCImageEditorController *)editorForSnapshot:(NSDictionary *)snapshot error:(NSError **)error;
@end

static moonbit_string_t String(NSString *value) {
    moonbit_string_t result=moonbit_make_string_raw((int32_t)value.length);
    [value getCharacters:result range:NSMakeRange(0,value.length)];
    return result;
}
static NSString *TakeString(moonbit_string_t value) {
    NSString *text=[[NSString alloc] initWithCharacters:value length:(NSUInteger)Moonbit_array_length(value)];
    moonbit_decref(value); return text;
}
static NSDictionary *JSON(NSString *text) {
    return [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
}
static NSData *Pixels(void) {
    NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:800 pixelsHigh:500
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:3200 bitsPerPixel:32];
    memset(bitmap.bitmapData,255,bitmap.bytesPerRow*bitmap.pixelsHigh);
    return [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}
static NSDictionary *Configuration(BOOL enabled) {
    NSDictionary *manifest=@{@"apiVersion":@2,@"pluginId":@"com.example.gesture",@"name":@"Gesture fixture",
        @"version":@"1.0.0",@"entry":@"plugin.wasm",@"runtime":@"extism-1",@"tools":@[
            @{@"toolId":@"box",@"title":@"Box",@"gesture":@"dragRect",@"effect":@"capture.annotations.add"},
            @{@"toolId":@"info",@"title":@"Info",@"gesture":@"invoke",@"effect":@"result.text"}]};
    NSDictionary *request=@{@"layout":@{@"version":@1,@"groups":@{@"screenshot":@[
        @{@"id":@"user.com.example.gesture/box",@"enabled":@(enabled)},
        @{@"id":@"user.com.example.gesture/info",@"enabled":@YES}]}},@"manifests":@[manifest]};
    NSString *json=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:request options:0 error:NULL]
        encoding:NSUTF8StringEncoding];
    moonbit_string_t input=String(json);
    NSDictionary *configuration=JSON(TakeString(tool_registry_resolve_packages(input)));
    moonbit_decref(input);
    NSCAssert([configuration[@"ok"] boolValue],@"Expected actual v2 registry: %@",configuration);
    return configuration;
}
static NSEvent *Mouse(MCImageCanvas *canvas, NSEventType type, NSPoint imagePoint) {
    NSRect frame=canvas.imageFrame;
    NSPoint point=NSMakePoint(frame.origin.x+imagePoint.x*frame.size.width/800,
                              frame.origin.y+imagePoint.y*frame.size.height/500);
    return [NSEvent mouseEventWithType:type location:[canvas convertPoint:point toView:nil] modifierFlags:0
        timestamp:0 windowNumber:canvas.window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
}
static void Begin(MCImageEditorController *editor, NSPoint point) {
    [editor.canvas mouseDown:Mouse(editor.canvas,NSEventTypeLeftMouseDown,point)];
}
static void Move(MCImageEditorController *editor, NSPoint point) {
    [editor.canvas mouseDragged:Mouse(editor.canvas,NSEventTypeLeftMouseDragged,point)];
}
static void End(MCImageEditorController *editor, NSPoint point) {
    [editor.canvas mouseUp:Mouse(editor.canvas,NSEventTypeLeftMouseUp,point)];
}
static MCImageEditorController *Editor(void) {
    MCImageEditorController *editor=[[MCImageEditorController alloc] initWithPNGData:Pixels() error:NULL];
    NSCAssert(editor,@"Create image editor");
    [editor prepareOverlayInFrame:NSMakeRect(0,0,800,500)];
    NSCAssert([editor setCaptureRegion:NSMakeRect(100,80,320,180)],@"Create viewport baseline");
    NSCAssert([editor canApplyToolConfiguration:Configuration(YES) error:NULL],@"Accept verified v2 configuration");
    [editor applyToolConfiguration:Configuration(YES)];
    return editor;
}
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        moonbit_init();
        MCImageEditorController *editor=Editor();
        NSString *box=@"user.com.example.gesture/box", *info=@"user.com.example.gesture/info";
        NSCAssert(!MCToolbarEnabled(editor.toolbar,box),@"Unavailable until a host callback exists");
        __block NSUInteger calls=0, legacyCalls=0;
        __block NSString *identifier=nil, *rawPayload=nil;
        __block int32_t session=0;
        editor.onUserTool=^(__unused MCImageEditorController *source, __unused NSString *tool) { legacyCalls++; };
        editor.onUserToolV2=^BOOL(MCImageEditorController *source,NSString *tool,NSString *payload,int32_t image) {
            calls++; identifier=tool; rawPayload=payload; session=image;
            NSCAssert(image==source.imageSession && image_session_revision(image)==[source.document[@"revision"] doubleValue],@"Borrow authoritative image session");
            NSCAssert([payload isEqual:TakeString(capture_toolbar_text(source.toolbarHandle,MC_CAPTURE_TOOLBAR_PAYLOAD))],@"Raw shared payload is forwarded unchanged");
            NSCAssert(image_session_count(image)==0 && !source.canvas.pending,@"Release has no provisional document mutation or native ghost");
            return YES;
        };
        MCToolbarClick(editor.toolbar,box);
        NSCAssert(calls==0 && legacyCalls==0,@"Selecting drag tool does not dispatch");
        Begin(editor,NSMakePoint(120,100)); Move(editor,NSMakePoint(280,180));
        NSCAssert(editor.canvas.dragging && editor.canvas.pending && image_session_count(editor.imageSession)==0,@"Move renders shared preview only");
        NSCAssert(![editor canApplyToolConfiguration:Configuration(NO) error:NULL],@"Active native drag vetoes configuration");
        End(editor,NSMakePoint(280,180));
        NSDictionary *payload=JSON(rawPayload);
        NSCAssert(calls==1 && legacyCalls==0 && [identifier isEqual:box] && session==editor.imageSession,@"Release dispatches v2 once with stable identity");
        NSCAssert(([payload[@"selection"] isEqual:@{@"x":@20,@"y":@20,@"width":@160,@"height":@80}]),@"MoonBit maps source to viewport coordinates exactly once");
        NSCAssert(([payload[@"capture"] isEqual:@{@"width":@320,@"height":@180,@"format":@"png",@"revision":@0}]),@"Payload includes shared revision and crop facts");
        NSCAssert(capture_toolbar_value(editor.toolbarHandle,MC_CAPTURE_TOOLBAR_EFFECT)==0,@"Dispatch ACK does not wait for asynchronous worker");
        End(editor,NSMakePoint(280,180));
        NSCAssert(calls==1 && image_session_revision(editor.imageSession)==0,@"Duplicate mouse release cannot invoke or add undo");
        Begin(editor,NSMakePoint(120,100)); End(editor,NSMakePoint(120,100));
        NSCAssert(calls==1,@"Click without area has no user effect");
        Begin(editor,NSMakePoint(120,100)); Move(editor,NSMakePoint(280,180));
        [editor.canvas cancelGesture]; End(editor,NSMakePoint(280,180));
        NSCAssert(calls==1 && !editor.canvas.pending,@"Cancellation clears shared preview and late mouse-up");
        MCToolbarClick(editor.toolbar,info);
        NSCAssert(calls==2 && [identifier isEqual:info] && [JSON(rawPayload)[@"effect"] isEqual:@"result.text"],@"Invoke action uses the same raw callback seam");
        editor.onUserToolV2=nil;
        MCToolbarClick(editor.toolbar,info);
        NSCAssert(legacyCalls==1 && calls==2,@"Legacy callback remains available until product cutover");
        editor.onUserToolV2=^BOOL(__unused MCImageEditorController *source,__unused NSString *tool,__unused NSString *payload,__unused int32_t image) { calls++; return NO; };
        MCToolbarClick(editor.toolbar,box);
        Begin(editor,NSMakePoint(120,100)); End(editor,NSMakePoint(280,180));
        NSCAssert(calls==3 && capture_toolbar_value(editor.toolbarHandle,MC_CAPTURE_TOOLBAR_EFFECT)==0,@"Rejected enqueue is still immediately ACKed");
        NSCAssert([editor canApplyToolConfiguration:Configuration(NO) error:NULL],@"No worker lease is retained in the toolbar after dispatch");
        [editor applyToolConfiguration:Configuration(NO)];
        NSCAssert(!MCToolbarEnabled(editor.toolbar,box),@"Post-dispatch configuration can disable the tool");
        [editor.window close];

        // Closing synchronously from a host callback must not ACK a recycled or
        // disposed toolbar, nor dereference the torn-down canvas afterward.
        MCImageEditorController *closing=Editor();
        closing.onUserToolV2=^BOOL(MCImageEditorController *source,__unused NSString *tool,__unused NSString *payload,__unused int32_t image) { [source.window close]; return YES; };
        MCToolbarClick(closing.toolbar,box);
        Begin(closing,NSMakePoint(120,100)); End(closing,NSMakePoint(280,180));
        NSCAssert(closing.window==nil && closing.imageSession==0,@"Synchronous callback retirement is safe");

        MCCaptureController *capture=[MCCaptureController new];
        capture.onUserToolV2=^BOOL(__unused MCImageEditorController *source,__unused NSString *tool,__unused NSString *payload,__unused int32_t image) { return YES; };
        MCImageEditorController *configured=[capture editorForSnapshot:@{@"png":Pixels(),@"frame":[NSValue valueWithRect:NSMakeRect(0,0,800,500)]} error:NULL];
        NSCAssert(configured.onUserToolV2!=nil,@"New capture editors inherit the optional v2 callback");
        [configured.window close];
        puts("capture plugin gesture: real mouse release, shared crop payload, cancellation, dispatch ACK, rejection, and legacy fallback passed");
    }
    return 0;
}
