#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>
#import "plugins/feature/capture_text/macos/MCTextRecognitionService.h"
#include <stdatomic.h>
#include <zlib.h>

// A standalone CLI: no NSApplication, windows, screen capture, or pasteboards.
// Compile the service with CGImageSourceCreateImageAtIndex redirected to the
// wrapper below. Decoding and Vision remain real; the wrapper observes whether
// rejected/queued input reaches decoding and can hold one decode for cancellation.
static atomic_uint DecodeCount;
static atomic_bool GateNextDecode;
static dispatch_semaphore_t DecodeEntered;
static dispatch_semaphore_t DecodeRelease;

@interface MCCopyTrackedData : NSData
@property NSData *storage;
@property NSUInteger copies;
@end
@implementation MCCopyTrackedData
- (NSUInteger)length { return self.storage.length; }
- (const void *)bytes { return self.storage.bytes; }
- (id)copyWithZone:(NSZone *)zone { self.copies++; return [self.storage copyWithZone:zone]; }
@end

static void Check(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL text recognition: %s\n", message.UTF8String); exit(1); }
}

CGImageRef MCTestCreateImageAtIndex(CGImageSourceRef source, size_t index, CFDictionaryRef options) {
    atomic_fetch_add(&DecodeCount, 1);
    if (atomic_exchange(&GateNextDecode, false)) {
        dispatch_semaphore_signal(DecodeEntered);
        Check(dispatch_semaphore_wait(DecodeRelease, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0,
              @"fixture must release the held decode");
    }
    return CGImageSourceCreateImageAtIndex(source, index, options);
}

@interface MCRecognitionCheck : NSObject
@property id<MCTextRecognitionTask> task;
@property NSString *text;
@property NSError *error;
@property NSUInteger completions;
@end
@implementation MCRecognitionCheck
@end

static MCRecognitionCheck *Start(MCTextRecognitionService *service, NSData *data) {
    MCRecognitionCheck *result = [MCRecognitionCheck new];
    result.task = [service recognizePNGData:data completion:^(NSString *text, NSError *error) {
        Check(NSThread.isMainThread, @"completion must run on the main thread");
        result.completions++;
        result.text = text;
        result.error = error;
    }];
    return result;
}

static void PumpUntil(BOOL (^condition)(void), NSTimeInterval seconds) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!condition() && deadline.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    Check(condition(), @"recognition did not finish within the fixture deadline");
}

static void Wait(MCRecognitionCheck *result) {
    PumpUntil(^BOOL { return result.completions > 0; }, 30);
    Check(result.completions == 1, @"completion must be delivered once");
}

static void CheckError(MCRecognitionCheck *result, MCTextRecognitionError code, NSString *label) {
    Wait(result);
    Check(result.text == nil && [result.error.domain isEqual:MCTextRecognitionErrorDomain] && result.error.code == code,
          [NSString stringWithFormat:@"%@: %@", label, result.error]);
}

static NSData *ImagePNG(BOOL withText) {
    const size_t width = 1200, height = 450;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, width * 4, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    Check(context != NULL, @"create generated screenshot bitmap");
    CGContextSetRGBFillColor(context, 1, 1, 1, 1);
    CGContextFillRect(context, CGRectMake(0, 0, width, height));
    if (withText) {
        CTFontRef font = CTFontCreateWithName(CFSTR("PingFangSC-Regular"), 56, NULL);
        CGColorRef black = CGColorCreateGenericRGB(0, 0, 0, 1);
        NSDictionary *attributes = @{(__bridge NSString *)kCTFontAttributeName:(__bridge id)font,
            (__bridge NSString *)kCTForegroundColorAttributeName:(__bridge id)black};
        NSArray<NSString *> *lines = @[@"HELLO WORLD", @"SCREEN CAPTURE", @"中文截图文字识别"];
        for (NSUInteger index = 0; index < lines.count; index++) {
            NSAttributedString *text = [[NSAttributedString alloc] initWithString:lines[index] attributes:attributes];
            CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)text);
            CGContextSetTextPosition(context, 48, 340 - index * 110);
            CTLineDraw(line, context);
            CFRelease(line);
        }
        CGColorRelease(black);
        CFRelease(font);
    }
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, CFSTR("public.png"), 1, NULL);
    Check(image && destination, @"create generated PNG encoder");
    CGImageDestinationAddImage(destination, image, NULL);
    Check(CGImageDestinationFinalize(destination), @"encode generated PNG");
    CFRelease(destination);
    CGImageRelease(image);
    return data;
}

static void PutU32(uint8_t *bytes, uint32_t value) {
    bytes[0] = (uint8_t)(value >> 24); bytes[1] = (uint8_t)(value >> 16);
    bytes[2] = (uint8_t)(value >> 8); bytes[3] = (uint8_t)value;
}

static NSData *DeclaredSize(NSData *png, uint32_t width, uint32_t height) {
    NSMutableData *data = [png mutableCopy];
    Check(data.length > 33 && memcmp((uint8_t *)data.bytes + 12, "IHDR", 4) == 0, @"PNG fixture starts with IHDR");
    uint8_t *bytes = data.mutableBytes;
    PutU32(bytes + 16, width); PutU32(bytes + 20, height);
    PutU32(bytes + 29, (uint32_t)crc32(0, bytes + 12, 17));
    return data;
}

static void PNGChunk(NSMutableData *png, const char type[4], NSData *payload) {
    uint8_t length[4]; PutU32(length, (uint32_t)payload.length);
    [png appendBytes:length length:4]; [png appendBytes:type length:4]; [png appendData:payload];
    uLong checksum = crc32(0, (const Bytef *)type, 4);
    checksum = crc32(checksum, payload.bytes, (uInt)payload.length);
    PutU32(length, (uint32_t)checksum); [png appendBytes:length length:4];
}

static NSData *OversizedPixelsPNG(void) {
    // A valid grayscale PNG just above the pixel limit. Compress the rows
    // directly, without allocating a decoded four-channel CGImage fixture.
    const uint32_t width = 8192, height = 4097;
    NSData *rows = [NSMutableData dataWithLength:(width + 1) * (size_t)height];
    uLongf compressedLength = compressBound(rows.length);
    NSMutableData *compressed = [NSMutableData dataWithLength:compressedLength];
    Check(compress2(compressed.mutableBytes, &compressedLength, rows.bytes, rows.length, Z_BEST_SPEED) == Z_OK,
          @"compress oversized PNG fixture");
    compressed.length = compressedLength;
    NSMutableData *png = [NSMutableData dataWithBytes:"\x89PNG\r\n\x1a\n" length:8];
    uint8_t header[13] = {0}; PutU32(header, width); PutU32(header + 4, height); header[8] = 8;
    PNGChunk(png, "IHDR", [NSData dataWithBytes:header length:sizeof(header)]);
    PNGChunk(png, "IDAT", compressed); PNGChunk(png, "IEND", [NSData data]);
    return png;
}

static NSString *Letters(NSString *text) {
    return [[[text lowercaseString] componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet] componentsJoinedByString:@""];
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        Check(argc == 2, @"usage: text-recognition-test /absolute/evidence/directory");
        NSURL *directory = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]] isDirectory:YES];
        Check([NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:NULL], @"create evidence directory");
        NSData *textPNG = ImagePNG(YES), *blankPNG = ImagePNG(NO);
        Check([textPNG writeToURL:[directory URLByAppendingPathComponent:@"english-chinese.png"] atomically:YES], @"save OCR input evidence");
        Check([blankPNG writeToURL:[directory URLByAppendingPathComponent:@"blank.png"] atomically:YES], @"save blank input evidence");
        MCTextRecognitionService *service = [MCTextRecognitionService new];
        NSMutableArray<MCRecognitionCheck *> *results = [NSMutableArray array];

        MCRecognitionCheck *recognized = Start(service, textPNG); [results addObject:recognized]; Wait(recognized);
        Check(!recognized.error, [NSString stringWithFormat:@"real bilingual Vision request: %@", recognized.error]);
        NSString *letters = Letters(recognized.text);
        for (NSString *expected in @[@"hello", @"world", @"screen", @"capture", @"截图", @"识别"])
            Check([letters containsString:expected], [NSString stringWithFormat:@"recognize %@ in %@", expected, recognized.text]);
        Check([recognized.text writeToURL:[directory URLByAppendingPathComponent:@"recognized.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL], @"save actual Vision output");
        printf("Real Vision bilingual output:\n%s\n", recognized.text.UTF8String);

        MCRecognitionCheck *blank = Start(service, blankPNG); [results addObject:blank]; Wait(blank);
        Check(!blank.error && [blank.text isEqual:@""], @"blank screenshot is successful no-text, not an error");
        MCRecognitionCheck *malformed = Start(service, [@"not a PNG" dataUsingEncoding:NSUTF8StringEncoding]); [results addObject:malformed];
        CheckError(malformed, MCTextRecognitionInvalidImage, @"malformed image");

        unsigned before = atomic_load(&DecodeCount);
        Check(before >= 2, @"decode wrapper must observe the real Vision inputs");
        MCCopyTrackedData *oversizedBytes = [MCCopyTrackedData new];
        oversizedBytes.storage = [NSMutableData dataWithLength:32 * 1024 * 1024 + 1];
        for (NSData *oversized in @[DeclaredSize(blankPNG, 8193, 1), OversizedPixelsPNG(), oversizedBytes]) {
            MCRecognitionCheck *result = Start(service, oversized); [results addObject:result];
            CheckError(result, MCTextRecognitionImageTooLarge, @"oversized input");
            Check(atomic_load(&DecodeCount) == before, @"reject encoded-byte, side and pixel limits before image decoding");
        }
        Check(oversizedBytes.copies == 0, @"reject over-budget mutable storage before making an immutable copy");

        MCRecognitionCheck *early = Start(service, textPNG); [results addObject:early]; [early.task cancel]; [early.task cancel];
        CheckError(early, MCTextRecognitionCancelled, @"early cancellation");

        DecodeEntered = dispatch_semaphore_create(0); DecodeRelease = dispatch_semaphore_create(0);
        before = atomic_load(&DecodeCount); atomic_store(&GateNextDecode, true);
        MCRecognitionCheck *first = Start(service, textPNG); [results addObject:first];
        Check(dispatch_semaphore_wait(DecodeEntered, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0,
              @"hold first real decode before enqueueing the cancelled task");
        MCRecognitionCheck *queued = Start(service, textPNG); [results addObject:queued]; [queued.task cancel];
        dispatch_semaphore_signal(DecodeRelease);
        Wait(first); Check(!first.error && [Letters(first.text) containsString:@"截图"], @"uncancelled first queued request still runs real Vision");
        CheckError(queued, MCTextRecognitionCancelled, @"queued cancellation");
        Check(atomic_load(&DecodeCount) == before + 1, @"queued cancellation must skip decoding entirely");

        for (MCRecognitionCheck *result in results) [result.task cancel];
        NSDate *settle = [NSDate dateWithTimeIntervalSinceNow:0.1];
        while (settle.timeIntervalSinceNow > 0)
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:settle];
        for (MCRecognitionCheck *result in results) Check(result.completions == 1, @"cancelling a completed request must not deliver twice");
        printf("Text recognition passed: real Chinese/English OCR, blank no-text, malformed input, pre-decode byte/side/pixel limits, early/queued cancellation, and exactly-once main-thread completions.\n");
    }
    return 0;
}
