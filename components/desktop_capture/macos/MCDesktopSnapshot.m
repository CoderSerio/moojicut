#import "MCDesktopSnapshot.h"
#include <math.h>

static NSError *MCSnapshotError(NSString *message) {
    return [NSError errorWithDomain:@"dev.moojicut.desktop-snapshot" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
void MCDesktopSnapshot(SCDisplay *display, NSArray<SCRunningApplication *> *excluded,
        NSArray<SCWindow *> *included, void (^completion)(NSData *, NSError *)) {
    if (@available(macOS 14.0, *)) {
        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingApplications:excluded exceptingWindows:included];
        SCStreamConfiguration *configuration = [SCStreamConfiguration new];
        configuration.width = (size_t)llround(filter.contentRect.size.width*filter.pointPixelScale);
        configuration.height = (size_t)llround(filter.contentRect.size.height*filter.pointPixelScale);
        configuration.showsCursor = NO;
        if (!configuration.width || !configuration.height || configuration.width > 32768 || configuration.height > 32768 || configuration.width*configuration.height > 80000000) {
            completion(nil,MCSnapshotError(@"屏幕尺寸无法处理，请调整显示器分辨率后重试。")); return;
        }
        [SCScreenshotManager captureImageWithFilter:filter configuration:configuration completionHandler:^(CGImageRef image, NSError *error) {
            @autoreleasepool {
                NSData *png = image ? [[[NSBitmapImageRep alloc] initWithCGImage:image] representationUsingType:NSBitmapImageFileTypePNG properties:@{}] : nil;
                completion(png,error ?: (png ? nil : MCSnapshotError(@"系统未能生成屏幕快照，请检查屏幕录制权限。")));
            }
        }];
    } else completion(nil,MCSnapshotError(@"原地选区需要 macOS 14 或更新版本。"));
}
