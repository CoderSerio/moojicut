#import "MCTextRecognitionService.h"
#import <Vision/Vision.h>
#import <ImageIO/ImageIO.h>

NSErrorDomain const MCTextRecognitionErrorDomain = @"dev.moojicut.text-recognition";
static NSError *MCTextError(MCTextRecognitionError code, NSString *message) {
    return [NSError errorWithDomain:MCTextRecognitionErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

@interface MCTextRecognitionOperation : NSObject <MCTextRecognitionTask>
@property BOOL cancelled;
@property VNRecognizeTextRequest *request;
@end
@implementation MCTextRecognitionOperation
- (void)cancel { @synchronized (self) { self.cancelled = YES; [self.request cancel]; } }
- (BOOL)installRequest:(VNRecognizeTextRequest *)request {
    @synchronized (self) { if (self.cancelled) return NO; self.request = request; return YES; }
}
- (BOOL)isCancelled { @synchronized (self) { return self.cancelled; } }
- (void)finish { @synchronized (self) { self.request = nil; } }
@end

@implementation MCTextRecognitionService
- (id<MCTextRecognitionTask>)recognizePNGData:(NSData *)data
                                 completion:(void (^)(NSString *, NSError *))completion {
    MCTextRecognitionOperation *operation = [MCTextRecognitionOperation new];
    // One shared worker prevents repeated clicks from decoding multiple large
    // screenshots at once. Cancellation is checked before decoding queued data.
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("dev.moojicut.vision", DISPATCH_QUEUE_SERIAL); });
    // Reject before copying potentially mutable storage on the caller's thread.
    // Keep the snapshot check below as well; no oversized input is retained.
    BOOL oversizedInput = data.length > 32 * 1024 * 1024;
    NSData *snapshot = oversizedInput ? nil : [data copy];
    dispatch_async(queue, ^{ @autoreleasepool {
        NSError *error = nil;
        NSString *text = nil;
        CGImageSourceRef source = NULL;
        CGImageRef image = NULL;
        if ([operation isCancelled]) {
            error = MCTextError(MCTextRecognitionCancelled, @"已取消文字识别。");
        } else if (oversizedInput || snapshot.length > 32 * 1024 * 1024) {
            error = MCTextError(MCTextRecognitionImageTooLarge, @"截图文件超过 32 MB，请缩小选区后重试。");
        } else {
            source = CGImageSourceCreateWithData((__bridge CFDataRef)snapshot, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceShouldCache: @NO});
            NSDictionary *properties = source ? CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL)) : nil;
            unsigned long long width = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] unsignedLongLongValue];
            unsigned long long height = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] unsignedLongLongValue];
            if (!source || ![(__bridge NSString *)CGImageSourceGetType(source) isEqual:@"public.png"] || !width || !height) {
                error = MCTextError(MCTextRecognitionInvalidImage, @"无法读取截图，请重新选择截图区域。");
            } else if (width > 8192 || height > 8192 || width * height > 32 * 1024 * 1024) {
                error = MCTextError(MCTextRecognitionImageTooLarge, @"截图尺寸过大（最长边 8192 像素、最多约 3355 万像素），请缩小选区后重试。");
            } else if (![operation isCancelled]) {
                image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
                if (!image) error = MCTextError(MCTextRecognitionInvalidImage, @"截图内容不完整，请重新截图。");
            }
        }
        if (image && ![operation isCancelled]) {
            VNRecognizeTextRequest *request = [VNRecognizeTextRequest new];
            request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
            request.usesLanguageCorrection = YES;
            request.automaticallyDetectsLanguage = YES;
            // Screenshots often contain small UI labels. Vision's default
            // minimum height (1/32 of the image) would silently ignore these.
            request.minimumTextHeight = 0;
            NSArray<NSString *> *supported = [request supportedRecognitionLanguagesAndReturnError:NULL];
            NSMutableOrderedSet *languages = [NSMutableOrderedSet orderedSet];
            for (NSString *language in @[@"zh-Hans", @"en-US", @"zh-Hant", @"ja-JP", @"ko-KR", @"fr-FR", @"de-DE", @"es-ES", @"pt-BR", @"it-IT"]) {
                if ([supported containsObject:language]) [languages addObject:language];
            }
            for (NSString *preferred in NSLocale.preferredLanguages) {
                NSString *code = [NSLocale localeWithLocaleIdentifier:preferred].languageCode;
                for (NSString *language in supported)
                    if ([[NSLocale localeWithLocaleIdentifier:language].languageCode isEqual:code]) [languages addObject:language];
            }
            if (languages.count) request.recognitionLanguages = languages.array;
            if ([operation installRequest:request]) {
                VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
                if ([handler performRequests:@[request] error:&error]) {
                    NSMutableArray<NSString *> *lines = [NSMutableArray array];
                    NSUInteger length = 0;
                    for (VNRecognizedTextObservation *observation in request.results) {
                        NSString *line = [observation topCandidates:1].firstObject.string;
                        if (line.length) {
                            length += [line lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + 1;
                            if (length > 128 * 1024) { error = MCTextError(MCTextRecognitionOutputTooLarge, @"识别内容超过 128 KB，请分区域识别。"); break; }
                            [lines addObject:line];
                        }
                    }
                    if (!error) text = [lines componentsJoinedByString:@"\n"];
                } else if (!error) {
                    error = MCTextError(MCTextRecognitionServiceFailed, @"系统文字识别暂时不可用，请重试。");
                }
            }
        }
        if (image) CGImageRelease(image);
        if (source) CFRelease(source);
        [operation finish];
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([operation isCancelled]) completion(nil, MCTextError(MCTextRecognitionCancelled, @"已取消文字识别。"));
            else completion(text, error);
        });
    }});
    return operation;
}
@end
