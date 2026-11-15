#import "MCScrollStitcher.h"
#import <ImageIO/ImageIO.h>
#include <math.h>

static NSError *MCScrollError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"dev.moojicut.scroll" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
static NSData *MCScrollDecode(NSData *png, NSUInteger *width, NSUInteger *height, NSError **error) {
    if (png.length > 16 * 1024 * 1024) { if (error) *error=MCScrollError(1,@"单帧图片太大，请缩小滚动截图区域。"); return nil; }
    CGImageSourceRef source=CGImageSourceCreateWithData((__bridge CFDataRef)png,NULL);
    if (!source) { if (error) *error=MCScrollError(1,@"无法读取滚动截图画面。"); return nil; }
    NSDictionary *properties=CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source,0,NULL));
    NSUInteger w=[properties[(__bridge NSString *)kCGImagePropertyPixelWidth] unsignedIntegerValue];
    NSUInteger h=[properties[(__bridge NSString *)kCGImagePropertyPixelHeight] unsignedIntegerValue];
    if (w<64 || h<96 || w>4096 || h>4096 || w*h>4000000) {
        CFRelease(source); if (error) *error=MCScrollError(1,@"请选择至少 64 × 96 像素、最多 400 万像素的滚动区域。"); return nil;
    }
    CGImageRef image=CGImageSourceCreateImageAtIndex(source,0,(__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceShouldCache:@NO});
    CFRelease(source);
    if (!image) { if (error) *error=MCScrollError(1,@"无法解码滚动截图画面。"); return nil; }
    NSMutableData *pixels=[NSMutableData dataWithLength:w*h*4];
    CGColorSpaceRef color=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context=CGBitmapContextCreate(pixels.mutableBytes,w,h,8,w*4,color,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(color);
    if (context) { CGContextDrawImage(context,CGRectMake(0,0,w,h),image); CGContextRelease(context); }
    CGImageRelease(image);
    if (!context) { if (error) *error=MCScrollError(1,@"无法创建滚动截图像素缓冲区。"); return nil; }
    *width=w;*height=h;return pixels;
}
// Ignore the outside 3% while aligning: a scroll indicator may change there.
// All pixels, including these edges, are retained in the final image.
static double MCRowDifference(const uint8_t *a,const uint8_t *b,NSUInteger width) {
    NSUInteger margin=MAX((NSUInteger)2,width/32), step=MAX((NSUInteger)1,(width-2*margin)/48);
    double sum=0;NSUInteger count=0;
    for (NSUInteger x=margin;x<width-margin;x+=step) for (NSUInteger c=0;c<3;c++) { sum+=abs((int)a[x*4+c]-(int)b[x*4+c]);count++; }
    return count?sum/count:255;
}
typedef struct { double mean; double mismatch; double texture; } MCAlignment;
static MCAlignment MCCompare(const uint8_t *a,const uint8_t *b,NSUInteger w,NSUInteger h,NSUInteger top,NSUInteger bottom,NSInteger dy,NSInteger dx,BOOL thorough) {
    NSInteger lo=(NSInteger)top+MAX(0,-dy),hi=(NSInteger)(h-bottom)-MAX(0,dy);
    NSInteger margin=(NSInteger)MAX((NSUInteger)2,w/32)+labs(dx),xs=margin,xe=(NSInteger)w-margin;
    if (hi-lo<32 || xe-xs<32) return (MCAlignment){255,1,0};
    NSInteger sy=thorough?1:MAX(1,(hi-lo)/48),sx=MAX(1,(xe-xs)/(thorough?96:40));
    double total=0,texture=0;NSUInteger count=0,bad=0;
    // Jitter within sample cells so repeated text baselines/blank line spacing
    // cannot alias a regular stride into an apparently perfect false match.
    for (NSInteger row=lo;row<hi;row+=sy) for (NSInteger col=xs;col<xe;col+=sx) {
        NSUInteger seed=(NSUInteger)(row-lo+1)*2654435761u;
        NSInteger y=MIN(hi-1,row+(NSInteger)(seed%(NSUInteger)sy));
        NSInteger x=MIN(xe-1,col+(NSInteger)((seed+(NSUInteger)col*2246822519u)%(NSUInteger)sx));
        const uint8_t *p=a+((y+dy)*w+x+dx)*4,*q=b+(y*w+x)*4;
        int worst=0;
        for(NSUInteger c=0;c<3;c++) {int diff=abs((int)p[c]-(int)q[c]);total+=diff;worst=MAX(worst,diff);}
        if(worst>14)bad++;
        const uint8_t *neighbor=b+(y*w+MIN(x+sx,xe-1))*4;
        texture+=abs((int)q[0]-(int)neighbor[0])+abs((int)q[1]-(int)neighbor[1])+abs((int)q[2]-(int)neighbor[2]);count++;
    }
    return (MCAlignment){total/MAX((NSUInteger)1,count*3),(double)bad/MAX((NSUInteger)1,count),texture/MAX((NSUInteger)1,count*3)};
}
@interface MCScrollStitcher ()
@property NSUInteger width;
@property NSUInteger height;
@property NSUInteger frameHeight;
@property NSUInteger acceptedFrames;
@property NSUInteger lastOffset;
@property NSUInteger fixedHeaderHeight;
@property NSUInteger fixedFooterHeight;
@property NSData *previous;
@property NSMutableData *stitched;
@property BOOL fixedEdgesKnown;
@end
@implementation MCScrollStitcher
- (MCScrollAppendResult)appendPNGData:(NSData *)data error:(NSError **)error {
    NSUInteger w=0,h=0;NSData *pixels=MCScrollDecode(data,&w,&h,error);
    if(!pixels)return MCScrollAppendRejected;
    if(!self.previous) {
        self.width=w;self.frameHeight=h;self.height=h;self.previous=pixels;self.stitched=[pixels mutableCopy];self.acceptedFrames=1;
        return MCScrollAppendFirstFrame;
    }
    if(w!=self.width || h!=self.frameHeight) {if(error)*error=MCScrollError(2,@"截图区域或显示器尺寸发生变化，请重新开始滚动截图。");return MCScrollAppendRejected;}
    const uint8_t *a=self.previous.bytes,*b=pixels.bytes;
    // Exact duplicate detection cannot overlook a small local content change.
    if([pixels isEqualToData:self.previous]) {self.lastOffset=0;return MCScrollAppendDuplicate;}
    NSUInteger top=0,bottom=0,maximumEdge=h/3;
    while(top<maximumEdge && MCRowDifference(a+top*w*4,b+top*w*4,w)<=0.8)top++;
    while(bottom<maximumEdge && MCRowDifference(a+(h-1-bottom)*w*4,b+(h-1-bottom)*w*4,w)<=0.8)bottom++;
    if(top<4)top=0;if(bottom<4)bottom=0;
    if(self.fixedEdgesKnown) {
        top=self.fixedHeaderHeight;bottom=self.fixedFooterHeight;
        for(NSUInteger y=0;y<h;y++) if((y<top || y>=h-bottom) && MCRowDifference(a+y*w*4,b+y*w*4,w)>2) {
            if(error)*error=MCScrollError(3,@"固定页头或页尾发生变化，请重新框选只包含滚动内容的区域。");return MCScrollAppendRejected;
        }
    }
    NSUInteger body=h-top-bottom,minimumOverlap=MAX((NSUInteger)40,body/4);
    NSInteger maximumShift=(NSInteger)body-(NSInteger)minimumOverlap;
    double best=255;NSInteger offset=0;NSMutableData *scores=[NSMutableData dataWithLength:(MAX((NSInteger)0,maximumShift)+1)*sizeof(double)];double *costs=scores.mutableBytes;
    for(NSInteger shift=1;shift<=maximumShift;shift++) {
        MCAlignment v=MCCompare(a,b,w,h,top,bottom,shift,0,NO);costs[shift]=v.mean;
        if(v.mean<best){best=v.mean;offset=shift;}
    }
    MCAlignment aligned=MCCompare(a,b,w,h,top,bottom,offset,0,YES);
    double alternative=255;
    for(NSInteger shift=1;shift<=maximumShift;shift++) if(labs(shift-offset)>3)alternative=MIN(alternative,costs[shift]);
    if(!offset || aligned.mean>2.0 || aligned.mismatch>0.025 || aligned.texture<0.8 || alternative<best+0.3) {
        // A few subpixel/scroll-indicator differences are not new content.
        MCAlignment still=MCCompare(a,b,w,h,0,0,0,0,YES);
        if(still.mean<0.35 && still.mismatch<0.002){self.lastOffset=0;return MCScrollAppendDuplicate;}
        for(NSInteger shift=1;shift<=maximumShift;shift++) {
            MCAlignment reverse=MCCompare(a,b,w,h,top,bottom,-shift,0,NO);
            if(reverse.mean<1 && reverse.texture>=0.8 && MCCompare(a,b,w,h,top,bottom,-shift,0,YES).mean<2) {
                if(error)*error=MCScrollError(4,@"检测到向上回滚。请继续向下滚动，或结束并保留已捕获的部分。");return MCScrollAppendRejected;
            }
        }
        for(NSInteger dx=-24;dx<=24;dx+=2) if(dx) {
            MCAlignment sideways=MCCompare(a,b,w,h,top,bottom,0,dx,YES);
            MCAlignment diagonal=MCCompare(a,b,w,h,top,bottom,offset,dx,YES);
            if((sideways.mean<1.5 && sideways.texture>=0.8) || (diagonal.mean<1.5 && diagonal.texture>=0.8)) {
                if(error)*error=MCScrollError(5,@"检测到画面横移。请保持窗口和水平滚动位置不变。");return MCScrollAppendRejected;
            }
        }
        if(error)*error=MCScrollError(6,@"画面无法可靠拼接。请慢些向下滚动并保留重叠；动态内容或重复图案可重新缩小选区。");return MCScrollAppendRejected;
    }
    NSUInteger newHeight=self.height+(NSUInteger)offset;
    if(newHeight>24000 || newHeight*w>12000000) {if(error)*error=MCScrollError(7,@"已达到长图上限（24,000 像素高或 1,200 万像素），请结束当前截图。");return MCScrollAppendRejected;}
    // Keep the first header, append only newly revealed body pixels, replace the
    // previous footer with the latest footer. Fixed chrome appears exactly once.
    [self.stitched setLength:(self.height-bottom)*w*4];
    [self.stitched appendBytes:b+(h-bottom-(NSUInteger)offset)*w*4 length:((NSUInteger)offset+bottom)*w*4];
    self.height=newHeight;self.previous=pixels;self.lastOffset=(NSUInteger)offset;self.acceptedFrames++;
    self.fixedHeaderHeight=top;self.fixedFooterHeight=bottom;self.fixedEdgesKnown=YES;
    return MCScrollAppendExtended;
}
- (NSData *)PNGDataWithError:(NSError **)error {
    if(!self.stitched.length){if(error)*error=MCScrollError(8,@"尚未捕获到画面。");return nil;}
    NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:self.width pixelsHigh:self.height bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bitmapFormat:0 bytesPerRow:self.width*4 bitsPerPixel:32];
    if(!bitmap){if(error)*error=MCScrollError(8,@"无法生成长图。");return nil;}
    memcpy(bitmap.bitmapData,self.stitched.bytes,self.stitched.length);
    NSData *png=[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if(!png && error)*error=MCScrollError(8,@"无法编码长图。");return png;
}
@end
