#import <AppKit/AppKit.h>

// Neutral selection chrome complements Mooji Cut's plum/cream identity.
// A darker under-stroke keeps it visible on both light and dark captures.
static inline NSColor *MCSelectionColor(void) {
    return [NSColor colorWithSRGBRed:0.76 green:0.75 blue:0.73 alpha:1];
}
static inline NSColor *MCSelectionContrastColor(void) {
    return [NSColor colorWithSRGBRed:0.17 green:0.14 blue:0.21 alpha:0.85];
}
static inline NSColor *MCSelectionHandleColor(void) {
    return [NSColor colorWithSRGBRed:0.98 green:0.96 blue:0.92 alpha:1];
}
static inline NSColor *MCSelectedToolColor(void) {
    return [NSColor colorWithSRGBRed:0.40 green:0.38 blue:0.42 alpha:1];
}
