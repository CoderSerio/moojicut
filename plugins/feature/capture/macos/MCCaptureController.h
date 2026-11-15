#import <AppKit/AppKit.h>

@class MCImageEditorController;
NS_ASSUME_NONNULL_BEGIN
@interface MCCaptureController : NSObject
@property (nonatomic, readonly) BOOL busy;
@property (nonatomic, copy, readonly, nullable) NSDictionary *toolConfiguration;
- (BOOL)canApplyToolConfiguration:(NSDictionary *)candidate error:(NSError **)error;
- (void)applyToolConfiguration:(NSDictionary *)candidate;
@property (nonatomic, copy, nullable) void (^onStateChange)(void);
@property (nonatomic, copy, nullable) void (^onUserTool)(MCImageEditorController *editor, NSString *identifier);
@property (nonatomic, copy, nullable) void (^onPluginContextClosed)(NSString *identifier);
@property (nonatomic, copy) NSDictionary<NSString *, NSImage *> *pluginIcons;
@property (nonatomic, copy, nullable) BOOL (^onPinPNGData)(NSData *data, NSRect screenFrame);
// Visible host-owned windows to retain in the frozen screen, such as pins.
// All other windows belonging to this process remain excluded from capture.
@property (nonatomic, copy, nullable) NSSet<NSNumber *> *(^includedWindowNumbers)(void);
- (void)capture;
- (void)cancelCapture;
- (BOOL)showEditorForPNGURL:(NSURL *)url error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
