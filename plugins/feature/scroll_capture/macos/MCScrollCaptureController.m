#import "MCScrollCaptureController.h"
#import "MCScrollStitcher.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include <math.h>

static NSError *MCScrollCaptureError(NSString *message) {
    return [NSError errorWithDomain:@"dev.moojicut.scroll.capture" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
NSRect MCScrollControlFrame(NSRect selection,NSArray<NSValue *> *visibleFrames,NSSize size) {
    const CGFloat gap=6;
    for(NSValue *value in visibleFrames) {
        NSRect available=NSInsetRect(value.rectValue,6,6);
        NSRect proposals[]={
            NSMakeRect(NSMinX(selection),NSMaxY(selection)+gap,size.width,size.height),
            NSMakeRect(NSMinX(selection),NSMinY(selection)-size.height-gap,size.width,size.height),
            NSMakeRect(NSMaxX(selection)+gap,NSMaxY(selection)-size.height,size.width,size.height),
            NSMakeRect(NSMinX(selection)-size.width-gap,NSMaxY(selection)-size.height,size.width,size.height),
            NSMakeRect(NSMinX(available),NSMinY(available),size.width,size.height),
        };
        for(NSUInteger i=0;i<sizeof(proposals)/sizeof(*proposals);i++) {
            NSRect candidate=proposals[i];
            candidate.origin.x=MAX(NSMinX(available),MIN(candidate.origin.x,NSMaxX(available)-size.width));
            candidate.origin.y=MAX(NSMinY(available),MIN(candidate.origin.y,NSMaxY(available)-size.height));
            if(NSContainsRect(available,candidate) && !NSIntersectsRect(candidate,NSInsetRect(selection,-3,-3)))return candidate;
        }
    }
    return NSZeroRect;
}
@interface MCScrollCaptureController ()
@property BOOL busy;
@property BOOL paused;
@property NSUInteger capturedHeight;
@property (copy) NSString *status;
@property (copy) MCScrollFrameProvider provider;
@property (copy) NSSet<NSNumber *> *(^includedWindowNumbers)(void);
@property MCScrollStitcher *stitcher;
@property dispatch_queue_t processingQueue;
@property NSTimer *timer;
@property NSUInteger generation;
@property NSUInteger requestNumber;
@property BOOL inFlight;
@property BOOL finishing;
@property BOOL needsFinalFrame;
@property BOOL screenSource;
@property NSRect screenRect;
@property NSRect displayFrame;
@property CGDirectDisplayID displayID;
@property NSPanel *panel;
@property NSTextField *statusLabel;
@property NSButton *finishButton;
@property NSButton *retryButton;
@property NSButton *cancelButton;
- (void)captureFrame;
@end
@implementation MCScrollCaptureController
- (instancetype)initWithFrameProvider:(MCScrollFrameProvider)provider {
    self=[super init];if(self){_provider=[provider copy];_status=@"准备滚动截图";
        _processingQueue=dispatch_queue_create("dev.moojicut.scroll.stitch",DISPATCH_QUEUE_SERIAL);}
    return self;
}
- (instancetype)initWithScreenRect:(NSRect)rect includedWindowNumbers:(NSSet<NSNumber *> *(^)(void))windowNumbers {
    self=[self initWithFrameProvider:^(MCScrollFrameCompletion complete){complete(nil,MCScrollCaptureError(@"截图区域不可用。"));}];
    if(self){
        _screenSource=YES;_screenRect=rect;_includedWindowNumbers=[windowNumbers copy];
        for(NSScreen *screen in NSScreen.screens) if(NSContainsRect(screen.frame,rect)) {
            _displayFrame=screen.frame;_displayID=[screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];break;
        }
        __weak MCScrollCaptureController *weakSelf=self;
        _provider=^(MCScrollFrameCompletion complete){[weakSelf captureScreen:complete];};
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(screenChanged:) name:NSApplicationDidChangeScreenParametersNotification object:nil];
    }
    return self;
}
- (void)changed {
    self.statusLabel.stringValue=self.status;self.statusLabel.toolTip=self.status;
    self.retryButton.enabled=self.paused;
    self.finishButton.enabled=self.capturedHeight>0;
    self.finishButton.title=self.paused?@"完成已捕获部分":@"完成";
    self.finishButton.toolTip=self.paused?@"保留暂停前已经成功拼接的内容，不包含未对齐的画面。":@"采集最后一帧，然后进入长图编辑。";
    if(self.panel && ![self layoutPanel]) {self.finishButton.title=self.paused?@"保留":@"完成";[self layoutPanel];}
    if(self.onStateChange)self.onStateChange();
}
- (void)screenChanged:(__unused NSNotification *)notification {
    if(self.busy)[self fail:MCScrollCaptureError(@"显示器配置已变化，滚动截图已取消。请重新框选。")];
}
- (NSArray<NSValue *> *)visibleFrames {
    NSMutableArray *frames=[NSMutableArray array];for(NSScreen *screen in NSScreen.screens)[frames addObject:[NSValue valueWithRect:screen.visibleFrame]];return frames;
}
- (BOOL)layoutPanel {
    CGFloat cancelWidth=MAX(52,self.cancelButton.fittingSize.width),retryWidth=MAX(80,self.retryButton.fittingSize.width);
    CGFloat finishWidth=MAX(62,self.finishButton.fittingSize.width);
    CGFloat width=cancelWidth+retryWidth+finishWidth+32,height=60;
    NSRect frame=MCScrollControlFrame(self.screenRect,[self visibleFrames],NSMakeSize(width,height));
    if(NSEqualRects(frame,NSZeroRect))return NO;
    [self.panel setFrame:frame display:NO];
    self.statusLabel.frame=NSMakeRect(10,35,width-20,19);
    self.cancelButton.frame=NSMakeRect(10,7,cancelWidth,25);
    self.retryButton.frame=NSMakeRect(16+cancelWidth,7,retryWidth,25);
    self.finishButton.frame=NSMakeRect(22+cancelWidth+retryWidth,7,finishWidth,25);
    return YES;
}
- (BOOL)showPanel {
    NSPanel *panel=[[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,260,60) styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
    panel.title=@"Mooji Cut · 滚动截图";panel.hidesOnDeactivate=NO;panel.level=NSStatusWindowLevel;
    panel.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary;
    panel.releasedWhenClosed=NO;panel.hasShadow=YES;
    NSVisualEffectView *root=[[NSVisualEffectView alloc] initWithFrame:panel.contentView.bounds];
    root.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    root.material=NSVisualEffectMaterialHUDWindow;root.state=NSVisualEffectStateActive;root.wantsLayer=YES;root.layer.cornerRadius=10;root.layer.masksToBounds=YES;panel.contentView=root;
    self.statusLabel=[NSTextField labelWithString:self.status];self.statusLabel.font=[NSFont systemFontOfSize:11];
    self.statusLabel.lineBreakMode=NSLineBreakByTruncatingTail;[root addSubview:self.statusLabel];
    self.cancelButton=[NSButton buttonWithTitle:@"取消" target:self action:@selector(cancel)];[root addSubview:self.cancelButton];
    self.retryButton=[NSButton buttonWithTitle:@"重试对齐" target:self action:@selector(retry)];[root addSubview:self.retryButton];
    self.finishButton=[NSButton buttonWithTitle:@"完成" target:self action:@selector(finish)];[root addSubview:self.finishButton];
    self.panel=panel;[self changed];
    if(!self.busy || self.panel!=panel)return NO;
    if(![self layoutPanel])return NO;
    [panel orderFrontRegardless];return YES;
}
- (void)start {
    NSAssert(NSThread.isMainThread,@"Scroll capture is owned by the main thread");
    if(self.busy)return;
    self.generation++;self.busy=YES;self.paused=NO;self.inFlight=NO;self.finishing=NO;self.needsFinalFrame=NO;
    self.capturedHeight=0;self.stitcher=[MCScrollStitcher new];self.status=@"正在捕获第一帧…";
    if(self.screenSource && (!self.displayID || NSWidth(self.screenRect)<32 || NSHeight(self.screenRect)<48)) {
        [self fail:MCScrollCaptureError(@"请在一个显示器内选择足够大的滚动区域。")];return;
    }
    if(self.screenSource && ![self showPanel]) {
        [self fail:MCScrollCaptureError(@"请缩小选区，在选区外留出滚动截图控制条的位置。")];return;
    }
    [self changed];if(!self.busy)return;
    [self beginTimer];[self captureFrame];
}
- (void)beginTimer {
    if(!self.busy || self.finishing)return;
    [self.timer invalidate];__weak MCScrollCaptureController *weakSelf=self;
    self.timer=[NSTimer timerWithTimeInterval:0.35 repeats:YES block:^(__unused NSTimer *timer){[weakSelf captureFrame];}];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}
- (void)captureFrame {
    if(!self.busy || self.paused || self.inFlight)return;
    self.inFlight=YES;NSUInteger generation=self.generation,request=++self.requestNumber;
    __weak MCScrollCaptureController *weakSelf=self;
    // The provider may finish on any queue or synchronously. All state changes
    // re-enter through the main queue; duplicate/late completions are ignored.
    self.provider(^(NSData *png,NSError *error){
        dispatch_async(dispatch_get_main_queue(),^{
            MCScrollCaptureController *owner=weakSelf;
            if(!owner.busy || owner.generation!=generation || owner.requestNumber!=request || !owner.inFlight)return;
            owner.requestNumber++; // consume this request before work is queued
            if(error || !png) {owner.inFlight=NO;[owner pause:error ?: MCScrollCaptureError(@"无法获取滚动画面。")];return;}
            MCScrollStitcher *stitcher=owner.stitcher;
            dispatch_async(owner.processingQueue,^{
                @autoreleasepool {
                    NSError *stitchError=nil;MCScrollAppendResult result=[stitcher appendPNGData:png error:&stitchError];
                    NSUInteger height=stitcher.height,frames=stitcher.acceptedFrames;
                    dispatch_async(dispatch_get_main_queue(),^{
                        MCScrollCaptureController *current=weakSelf;
                        if(!current.busy || current.generation!=generation)return;
                        current.inFlight=NO;
                        if(result==MCScrollAppendRejected){[current pause:stitchError];return;}
                        current.capturedHeight=height;
                        current.status=[NSString stringWithFormat:@"已捕获 %lu 像素高（%lu 帧）。继续向下滚动，结束时点击“完成”。",(unsigned long)height,(unsigned long)frames];
                        [current changed];if(!current.busy || current.generation!=generation)return;
                        if(current.finishing){
                            if(current.needsFinalFrame){current.needsFinalFrame=NO;[current captureFrame];}
                            else [current completeImage];
                        }
                    });
                }
            });
        });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        MCScrollCaptureController *owner=weakSelf;
        if(owner.busy && owner.generation==generation && owner.requestNumber==request && owner.inFlight){
            owner.requestNumber++;owner.inFlight=NO;[owner pause:MCScrollCaptureError(@"获取屏幕画面超时。请检查权限或重试。")];
        }
    });
}
- (void)pause:(NSError *)error {
    if(!self.capturedHeight){[self fail:error];return;}
    self.paused=YES;self.finishing=NO;self.needsFinalFrame=NO;[self.timer invalidate];self.timer=nil;
    self.status=[@"暂停拼接：" stringByAppendingString:error.localizedDescription ?: @"画面无法对齐。"];
    [self changed];
}
- (void)retry {
    NSAssert(NSThread.isMainThread,@"Scroll capture is owned by the main thread");
    if(!self.busy || !self.paused)return;
    self.paused=NO;self.status=@"正在重新对齐；已捕获的部分保持不变。";[self changed];
    if(self.busy && !self.finishing){[self beginTimer];[self captureFrame];}
}
- (void)finish {
    NSAssert(NSThread.isMainThread,@"Scroll capture is owned by the main thread");
    if(!self.busy || self.finishing)return;
    [self.timer invalidate];self.timer=nil;
    if(self.paused){self.finishing=YES;[self completeImage];return;}
    self.finishing=YES;self.needsFinalFrame=self.inFlight;
    self.status=@"正在捕获最后一帧并生成长图…";[self changed];
    if(self.busy && !self.inFlight)[self captureFrame];
}
- (void)completeImage {
    NSUInteger generation=self.generation;MCScrollStitcher *stitcher=self.stitcher;
    __weak MCScrollCaptureController *weakSelf=self;
    dispatch_async(self.processingQueue,^{
        @autoreleasepool {
            NSError *error=nil;NSData *png=[stitcher PNGDataWithError:&error];
            dispatch_async(dispatch_get_main_queue(),^{
                MCScrollCaptureController *owner=weakSelf;
                if(!owner.busy || owner.generation!=generation)return;
                [owner end];if(owner.onCompletion)owner.onCompletion(png,error);
            });
        }
    });
}
- (void)end {
    self.generation++;self.busy=NO;self.inFlight=NO;[self.timer invalidate];self.timer=nil;
    [self.panel orderOut:nil];[self.panel close];self.panel=nil;self.statusLabel=nil;self.finishButton=nil;self.retryButton=nil;self.cancelButton=nil;self.stitcher=nil;
    [self changed];
}
- (void)fail:(NSError *)error {
    if(!self.busy)return;[self end];if(self.onCompletion)self.onCompletion(nil,error);
}
- (void)cancel {
    NSAssert(NSThread.isMainThread,@"Scroll capture is owned by the main thread");
    if(self.busy)[self fail:[NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil]];
}
- (void)captureScreen:(MCScrollFrameCompletion)complete {
    NSRect selection=self.screenRect,displayFrame=self.displayFrame;CGDirectDisplayID displayID=self.displayID;
    NSSet<NSNumber *> *included=self.includedWindowNumbers?self.includedWindowNumbers():[NSSet set];
    CGWindowID HUDWindow=(CGWindowID)self.panel.windowNumber;
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:YES completionHandler:^(SCShareableContent *content,NSError *error){
        if(!content || error){complete(nil,error ?: MCScrollCaptureError(@"无法读取屏幕，请检查屏幕录制权限。"));return;}
        SCDisplay *display=nil;for(SCDisplay *candidate in content.displays)if(candidate.displayID==displayID){display=candidate;break;}
        if(!display){complete(nil,MCScrollCaptureError(@"原显示器已不可用，请重新框选。"));return;}
        NSMutableArray *excluded=[NSMutableArray array],*pins=[NSMutableArray array];
        pid_t pid=NSProcessInfo.processInfo.processIdentifier;
        for(SCRunningApplication *app in content.applications)if(app.processID==pid)[excluded addObject:app];
        for(SCWindow *window in content.windows)if(window.owningApplication.processID==pid) {
            if(!excluded.count && window.owningApplication)[excluded addObject:window.owningApplication];
            if(window.windowID!=HUDWindow && window.onScreen && [included containsObject:@(window.windowID)])[pins addObject:window];
        }
        SCContentFilter *filter=[[SCContentFilter alloc] initWithDisplay:display excludingApplications:excluded exceptingWindows:pins];
        SCStreamConfiguration *configuration=[SCStreamConfiguration new];
        configuration.sourceRect=CGRectMake(NSMinX(selection)-NSMinX(displayFrame),NSMaxY(displayFrame)-NSMaxY(selection),NSWidth(selection),NSHeight(selection));
        configuration.width=(size_t)llround(NSWidth(selection)*filter.pointPixelScale);
        configuration.height=(size_t)llround(NSHeight(selection)*filter.pointPixelScale);
        configuration.showsCursor=NO;
        if(!configuration.width || !configuration.height || configuration.width>4096 || configuration.height>4096 || configuration.width*configuration.height>4000000){
            complete(nil,MCScrollCaptureError(@"截图区域超过 400 万像素，请缩小选区。"));return;
        }
        [SCScreenshotManager captureImageWithFilter:filter configuration:configuration completionHandler:^(CGImageRef image,NSError *failure){
            @autoreleasepool {
                NSData *png=image?[[[NSBitmapImageRep alloc] initWithCGImage:image] representationUsingType:NSBitmapImageFileTypePNG properties:@{}]:nil;
                complete(png,failure ?: (png?nil:MCScrollCaptureError(@"系统未返回滚动截图画面。")));
            }
        }];
    }];
}
- (void)dealloc {[self.timer invalidate];[NSNotificationCenter.defaultCenter removeObserver:self];}
@end
