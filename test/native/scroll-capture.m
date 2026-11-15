#import <AppKit/AppKit.h>
#import "plugins/feature/scroll_capture/macos/MCScrollStitcher.h"
#import "plugins/feature/scroll_capture/macos/MCScrollCaptureController.h"
#include <math.h>
#define CHECK(c,m) do{if(!(c)){fprintf(stderr,"FAIL scroll capture: %s\n",m);passed=NO;}}while(0)

// A synthetic document with unique text-like strokes, blank lines and fixed
// page chrome. Expected long images are rendered directly from document y,
// independently of the stitcher's overlap search.
static void pixel(uint8_t *p,NSInteger x,NSInteger y) {
    uint32_t key=(uint32_t)(y/17+1)*2654435761u+(uint32_t)(x/9)*2246822519u;
    BOOL stroke=(y%17)<10 && x>10 && x<170 && ((key>>(x%7))&3)!=0;
    p[0]=stroke?30+(key%70):245;p[1]=stroke?45+(key%60):246;p[2]=stroke?60+(key%50):248;p[3]=255;
}
static NSData *frame(NSInteger offset,NSInteger dx,NSUInteger w,NSUInteger h,NSUInteger header,NSUInteger footer,BOOL constant) {
    NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:w*4 bitsPerPixel:32];
    for(NSUInteger y=0;y<h;y++)for(NSUInteger x=0;x<w;x++){
        uint8_t *p=bitmap.bitmapData+y*bitmap.bytesPerRow+x*4;
        if(constant){p[0]=p[1]=p[2]=240;p[3]=255;}
        else if(y<header || y>=h-footer){p[0]=40+x%120;p[1]=y<header?70:120;p[2]=y<header?180:60;p[3]=255;}
        else pixel(p,((NSInteger)x+dx)%192,(NSInteger)(y-header)+offset);
    }
    return [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}
static NSData *textFrame(NSUInteger offset) {
    NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:384 pixelsHigh:320 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:1536 bitsPerPixel:32];
    memset(bitmap.bitmapData,255,384*320*4);
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext=[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    NSDictionary *attributes=@{NSFontAttributeName:[NSFont monospacedSystemFontOfSize:14 weight:NSFontWeightRegular],NSForegroundColorAttributeName:NSColor.blackColor};
    for(NSUInteger line=0;line<80;line++) {
        NSInteger y=(NSInteger)(line*25)-(NSInteger)offset;
        if(y>-25 && y<320) {
            NSString *text=[NSString stringWithFormat:@"Row %03lu: notes %lu / %lu",(unsigned long)line,(unsigned long)(line*17+43),(unsigned long)(line*line+19)];
            [text drawAtPoint:NSMakePoint(10,320-y-20) withAttributes:attributes];
        }
    }
    [NSGraphicsContext restoreGraphicsState];
    return [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}
static NSData *canonical(NSData *input) {MCScrollStitcher *s=[MCScrollStitcher new];[s appendPNGData:input error:NULL];return [s PNGDataWithError:NULL];}
static BOOL samePixels(NSData *a,NSData *b){
    NSBitmapImageRep *left=[NSBitmapImageRep imageRepWithData:a],*right=[NSBitmapImageRep imageRepWithData:b];
    if(left.pixelsWide!=right.pixelsWide || left.pixelsHigh!=right.pixelsHigh)return NO;
    for(NSInteger y=0;y<left.pixelsHigh;y++)for(NSInteger x=0;x<left.pixelsWide;x++){
        NSUInteger l[4]={0},r[4]={0};[left getPixel:l atX:x y:y];[right getPixel:r atX:x y:y];
        for(NSUInteger c=0;c<4;c++)if(l[c]!=r[c])return NO;
    }
    return YES;
}
static BOOL waitFor(BOOL (^ready)(void)) {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:3];
    while(!ready() && deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.005]];
    return ready();
}
int main(void){@autoreleasepool{
    BOOL passed=YES;
    NSRect selection=NSMakeRect(100,75,1000,650);
    NSRect controls=MCScrollControlFrame(selection,@[[NSValue valueWithRect:NSMakeRect(0,0,1200,800)]],NSMakeSize(280,60));
    CHECK(!NSEqualRects(controls,NSZeroRect) && !NSIntersectsRect(selection,controls) && NSContainsRect(NSMakeRect(0,0,1200,800),controls),"compact HUD fits outside a typical 1000x650 selection on 1200x800 screen");
    NSRect full=NSMakeRect(0,0,1200,800);
    CHECK(NSEqualRects(MCScrollControlFrame(full,@[[NSValue valueWithRect:full]],NSMakeSize(280,60)),NSZeroRect),"full-screen selection does not silently cover content with HUD");
    controls=MCScrollControlFrame(full,@[[NSValue valueWithRect:full],[NSValue valueWithRect:NSMakeRect(-1000,0,1000,800)]],NSMakeSize(280,60));
    CHECK(NSContainsRect(NSMakeRect(-1000,0,1000,800),controls),"HUD uses neighboring display when selected display has no space");
    NSError *error=nil;NSUInteger w=192,h=240,header=24,footer=20;
    NSData *first=frame(0,0,w,h,header,footer,NO),*next=frame(53,0,w,h,header,footer,NO),*last=frame(108,0,w,h,header,footer,NO);
    MCScrollStitcher *s=[MCScrollStitcher new];
    CHECK([s appendPNGData:first error:&error]==MCScrollAppendFirstFrame,"first frame accepted");
    CHECK([s appendPNGData:first error:&error]==MCScrollAppendDuplicate && s.height==h && s.acceptedFrames==1,"duplicate does not grow image");
    CHECK([s appendPNGData:next error:&error]==MCScrollAppendExtended,"overlap accepted with fixed header/footer");
    if(error)fprintf(stderr,"detail: %s\n",error.localizedDescription.UTF8String);
    CHECK(s.height==h+53 && s.lastOffset==53,"measured movement determines output height");
    CHECK([s appendPNGData:last error:&error]==MCScrollAppendExtended && s.height==h+108,"second nonuniform movement extends image");
    CHECK(samePixels([s PNGDataWithError:NULL],canonical(frame(0,0,w,h+108,header,footer,NO))),"exact final pixels keep header/footer once and body without omissions");
    NSData *accepted=[s PNGDataWithError:NULL];error=nil;
    CHECK([s appendPNGData:next error:&error]==MCScrollAppendRejected && error.code==4,"upward scrolling is rejected");
    CHECK(samePixels([s PNGDataWithError:NULL],accepted) && s.acceptedFrames==3,"rejection preserves accepted image and frame reference");
    error=nil;CHECK([s appendPNGData:frame(108,8,w,h,header,footer,NO) error:&error]==MCScrollAppendRejected && error.code==5,"horizontal movement is reported explicitly and cannot silently extend image");
    error=nil;CHECK([s appendPNGData:frame(800,0,w,h,header,footer,NO) error:&error]==MCScrollAppendRejected,"missing overlap rejected");
    CHECK(samePixels([s PNGDataWithError:NULL],accepted),"failed alignment leaves output unchanged");
    error=nil;CHECK([s appendPNGData:frame(108,0,w+1,h,header,footer,NO) error:&error]==MCScrollAppendRejected && error.code==2,"changed region dimensions rejected");
    error=nil;CHECK([s appendPNGData:[NSData dataWithBytes:"bad" length:3] error:&error]==MCScrollAppendRejected,"malformed PNG rejected");
    MCScrollStitcher *blank=[MCScrollStitcher new];NSData *white=frame(0,0,w,h,0,0,YES);
    [blank appendPNGData:white error:NULL];CHECK([blank appendPNGData:white error:NULL]==MCScrollAppendDuplicate,"blank duplicate stays one frame");
    MCScrollStitcher *plain=[MCScrollStitcher new];
    [plain appendPNGData:frame(0,0,w,h,0,0,NO) error:NULL];
    CHECK([plain appendPNGData:frame(69,0,w,h,0,0,NO) error:&error]==MCScrollAppendExtended,"content without fixed chrome stitches");
    CHECK(samePixels([plain PNGDataWithError:NULL],canonical(frame(0,0,w,h+69,0,0,NO))),"plain scrolling preserves exact full image");

    MCScrollStitcher *textPage=[MCScrollStitcher new];
    [textPage appendPNGData:textFrame(0) error:NULL];error=nil;
    CHECK([textPage appendPNGData:textFrame(67) error:&error]==MCScrollAppendExtended && textPage.lastOffset==67,"native rasterized text page aligns by actual pixel content");
    MCScrollStitcher *bounded=[MCScrollStitcher new];BOOL hitLimit=NO;NSUInteger previousHeight=0;
    for(NSUInteger step=0;step<44;step++) {
        error=nil;MCScrollAppendResult r=[bounded appendPNGData:frame(step*300,0,1024,512,0,0,NO) error:&error];
        if(r==MCScrollAppendRejected){if(error.code!=7)fprintf(stderr,"budget rejection step=%lu code=%ld message=%s\n",(unsigned long)step,(long)error.code,error.localizedDescription.UTF8String);hitLimit=error.code==7;CHECK(bounded.height==previousHeight,"limit rejection leaves accepted image height intact");break;}
        previousHeight=bounded.height;
    }
    CHECK(hitLimit && bounded.width*bounded.height<=12000000,"pixel budget stops long captures before exceeding the limit");

    __block NSUInteger earlyFailures=0;
    MCScrollCaptureController *invalid=[[MCScrollCaptureController alloc] initWithScreenRect:NSZeroRect includedWindowNumbers:nil];
    invalid.onCompletion=^(NSData *png,NSError *failure){if(!png && failure)earlyFailures++;};
    [invalid start];[invalid cancel];
    CHECK(!invalid.busy && earlyFailures==1,"invalid screen region completes exactly once before any HUD or capture request");

    // No windows or screen permission: exercise the real asynchronous controller
    // with a provider seam, including completion after cancel and repeated calls.
    __block NSUInteger requested=0,completed=0;__block MCScrollFrameCompletion pending=nil;__block NSData *result=nil;__block NSError *completionError=nil;
    MCScrollCaptureController *controller=[[MCScrollCaptureController alloc] initWithFrameProvider:^(MCScrollFrameCompletion c){requested++;pending=[c copy];}];
    controller.onCompletion=^(NSData *png,NSError *e){completed++;result=png;completionError=e;};
    [controller start];CHECK(controller.busy && requested==1,"start requests first frame");
    MCScrollFrameCompletion firstCompletion=pending;firstCompletion(first,nil);firstCompletion(next,nil);
    CHECK(waitFor(^BOOL{return controller.capturedHeight==h;}),"first async frame processed once");
    [controller finish];CHECK(requested==2 && controller.busy,"finish requests a fresh last frame");
    pending(next,nil);CHECK(waitFor(^BOOL{return !controller.busy;}),"finish completes after final processing");
    CHECK(completed==1 && result && !completionError && [NSBitmapImageRep imageRepWithData:result].pixelsHigh==(NSInteger)(h+53),"result contains final captured frame");
    [controller start];MCScrollFrameCompletion cancelled=pending;[controller cancel];[controller cancel];NSUInteger completedAtCancel=completed;
    cancelled(first,nil);CHECK(waitFor(^BOOL{return !controller.busy;}),"cancel ends session");
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.03]];
    CHECK(completedAtCancel==2 && completed==2 && completionError.code==NSUserCancelledError && !result,"late provider result cannot revive cancelled session");
    [controller start];pending(first,nil);CHECK(waitFor(^BOOL{return controller.capturedHeight==h;}),"restart uses clean state");
    [controller finish];pending(frame(900,0,w,h,header,footer,NO),nil);
    CHECK(waitFor(^BOOL{return controller.paused;}),"bad final frame pauses explicitly instead of returning a bad stitch");
    [controller finish];CHECK(waitFor(^BOOL{return !controller.busy;}),"user may explicitly keep accepted partial image");
    CHECK(result && [NSBitmapImageRep imageRepWithData:result].pixelsHigh==(NSInteger)h,"partial output contains only accepted pixels");
    [controller start];MCScrollFrameCompletion inFlight=pending;NSUInteger before=requested;[controller finish];
    inFlight(first,nil);CHECK(waitFor(^BOOL{return requested==before+1;}),"finish during pending capture waits and requests one final fresh frame");
    pending(next,nil);CHECK(waitFor(^BOOL{return !controller.busy;}),"pending finish delivers once final request is processed");
    CHECK(result && [NSBitmapImageRep imageRepWithData:result].pixelsHigh==(NSInteger)(h+53),"pending final capture includes newest pixels");
    [controller start];NSUInteger requestAtTimeout=requested;
    NSDate *timeoutDeadline=[NSDate dateWithTimeIntervalSinceNow:6];
    while(controller.busy && timeoutDeadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
    CHECK(!controller.busy && requested==requestAtTimeout && completionError && !result,"hung provider is bounded to one request and times out");
    puts(passed?"PASS scroll capture: overlap, fixed chrome, repeated frames, exact pixels, reverse/horizontal/gap rejection, cancellation, final-frame capture and partial results":"FAIL scroll capture");
    return passed?0:1;
}}
