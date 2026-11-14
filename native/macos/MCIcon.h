#import <AppKit/AppKit.h>
#include "../shared/mc_icons.h"

// AppKit rasterizes this vector representation at the current display scale.
static inline NSImage *MCIconImage(MCIcon icon, NSString *label) {
    NSImage *image = [NSImage imageWithSize:NSMakeSize(18, 18) flipped:NO
        drawingHandler:^BOOL(NSRect rect) {
            MCIconPath data = mc_icon_path(icon);
            if (!data.count) return NO;
            [NSGraphicsContext saveGraphicsState];
            NSAffineTransform *transform = [NSAffineTransform transform];
            [transform translateXBy:NSMinX(rect) yBy:NSMaxY(rect)];
            [transform scaleXBy:rect.size.width / 24 yBy:-rect.size.height / 24];
            [transform concat];
            NSBezierPath *path = [NSBezierPath bezierPath];
            path.lineWidth = 2;
            path.lineCapStyle = NSLineCapStyleRound;
            path.lineJoinStyle = NSLineJoinStyleRound;
            for (unsigned i = 0; i < data.count; i++) {
                MCIconCommand command = data.commands[i];
                switch (command.op) {
                    case 'M': [path moveToPoint:NSMakePoint(command.x1, command.y1)]; break;
                    case 'L': [path lineToPoint:NSMakePoint(command.x1, command.y1)]; break;
                    case 'C': [path curveToPoint:NSMakePoint(command.x3, command.y3)
                        controlPoint1:NSMakePoint(command.x1, command.y1)
                        controlPoint2:NSMakePoint(command.x2, command.y2)]; break;
                    case 'Z': [path closePath]; break;
                }
            }
            [NSColor.blackColor setStroke];
            [path stroke];
            [NSGraphicsContext restoreGraphicsState];
            return YES;
        }];
    image.template = YES;
    image.accessibilityDescription = label;
    return image;
}
