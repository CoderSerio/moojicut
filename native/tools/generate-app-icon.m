#import <AppKit/AppKit.h>

// Build-time only: preserve the approved Lunar Frame artwork and add the
// transparent margin expected by traditional macOS .icns application icons.
static NSData *MCIconPNG(NSImage *artwork, NSInteger pixels) {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:pixels pixelsHigh:pixels bitsPerSample:8 samplesPerPixel:4
        hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    NSGraphicsContext.currentContext.imageInterpolation = NSImageInterpolationHigh;
    CGFloat scale = (CGFloat)pixels / 1024.0;
    [artwork drawInRect:NSMakeRect(96 * scale, 96 * scale, 832 * scale, 832 * scale)
        fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:NO hints:nil];
    [NSGraphicsContext restoreGraphicsState];
    return [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) { fprintf(stderr, "Usage: generate-app-icon ARTWORK_PNG ICONSET_DIRECTORY\n"); return 2; }
        NSImage *artwork = [[NSImage alloc] initWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
        if (!artwork || !artwork.valid) { fprintf(stderr, "Cannot load the Mooncap artwork.\n"); return 1; }
        NSString *directory = [NSString stringWithUTF8String:argv[2]];
        NSError *error = nil;
        if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error]) {
            fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1;
        }
        for (NSNumber *size in @[@16, @32, @128, @256, @512]) {
            for (NSInteger factor = 1; factor <= 2; factor++) {
                NSString *filename = [NSString stringWithFormat:@"icon_%ldx%ld%@.png", size.longValue, size.longValue, factor == 2 ? @"@2x" : @""];
                NSData *png = MCIconPNG(artwork, size.integerValue * factor);
                if (!png || ![png writeToFile:[directory stringByAppendingPathComponent:filename] options:NSDataWritingAtomic error:&error]) {
                    fprintf(stderr, "Cannot write %s: %s\n", filename.UTF8String, error.localizedDescription.UTF8String); return 1;
                }
            }
        }
    }
    return 0;
}
