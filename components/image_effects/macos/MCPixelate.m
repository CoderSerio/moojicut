#import "MCPixelate.h"
#include <math.h>

NSImage *MCPixelatedRegion(NSRect region, CGFloat blockSize, void (^drawUnderlying)(void), NSRect *grid) {
    if (NSIsEmptyRect(region) || !isfinite(blockSize) || blockSize < 4 || blockSize > 48) return nil;
    CGFloat left = floor(NSMinX(region) / blockSize) * blockSize;
    CGFloat top = floor(NSMinY(region) / blockSize) * blockSize;
    NSInteger columns = (NSInteger)ceil((NSMaxX(region) - left) / blockSize);
    NSInteger rows = (NSInteger)ceil((NSMaxY(region) - top) / blockSize);
    if (columns < 1 || rows < 1 || columns > 8193 || rows > 8193 || columns * rows > 5100000) return nil;
    *grid = NSMakeRect(left, top, columns * blockSize, rows * blockSize);
    NSBitmapImageRep *pixels = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:columns pixelsHigh:rows
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:columns*4 bitsPerPixel:32];
    if (!pixels) return nil;
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:pixels];
    if (!context) return nil;
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:context.CGContext flipped:YES];
    NSGraphicsContext.currentContext.imageInterpolation = NSImageInterpolationHigh;
    NSAffineTransform *transform = [NSAffineTransform transform];
    [transform translateXBy:0 yBy:rows];
    [transform scaleXBy:1 / blockSize yBy:-1 / blockSize];
    [transform translateXBy:-left yBy:-top];
    [transform concat];
    drawUnderlying();
    [NSGraphicsContext restoreGraphicsState];
    NSImage *result = [[NSImage alloc] initWithSize:NSMakeSize(columns, rows)];
    [result addRepresentation:pixels];
    return result;
}
