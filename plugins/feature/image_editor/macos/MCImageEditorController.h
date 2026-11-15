#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
@interface MCImageEditorController : NSObject <NSWindowDelegate>
@property (nonatomic, readonly, nullable) NSWindow *window;
@property (nonatomic, readonly) NSDictionary *document;
@property (nonatomic, readonly) NSRect pinScreenFrame;
@property (nonatomic, readonly) NSRect captureScreenFrame;
// Small immutable content identity for asynchronous consumers. Compare on the
// main thread before presenting results; nil means closed or temporarily invalid
// (unfinished input, selection or annotation gesture).
@property (nonatomic, readonly, nullable) NSDictionary *captureContentSnapshot;
@property (nonatomic, copy, readonly, nullable) NSDictionary *toolConfiguration;
@property (nonatomic, copy, nullable) void (^onClose)(void);
@property (nonatomic, copy, readonly) NSString *pluginContextIdentifier;
@property (nonatomic, readonly, nullable) NSDictionary *pluginCaptureMetadata;
@property (nonatomic, copy, nullable) void (^onUserTool)(MCImageEditorController *editor, NSString *identifier);
@property (nonatomic, copy, nullable) void (^onOCR)(MCImageEditorController *editor);
@property (nonatomic, copy, nullable) void (^onTranslate)(MCImageEditorController *editor);
@property (nonatomic, copy, nullable) void (^onScrollCapture)(MCImageEditorController *editor);
@property (nonatomic, copy, nullable) void (^onPluginContextClosed)(NSString *identifier);
@property (nonatomic, copy) NSDictionary<NSString *, NSImage *> *pluginIcons;
- (void)showPluginMessage:(NSString *)message;
@property (nonatomic, copy, nullable) BOOL (^onPinPNGData)(NSData *data);
- (nullable instancetype)initWithPNGData:(NSData *)data error:(NSError **)error;
// Call preflight for every editor before applying on the main thread.
// A failed preflight leaves the configuration, input and document untouched.
- (BOOL)canApplyToolConfiguration:(NSDictionary *)candidate error:(NSError **)error;
- (void)applyToolConfiguration:(NSDictionary *)candidate;
- (void)show;
- (void)prepareOverlayInFrame:(NSRect)screenFrame;
- (BOOL)applyAnnotation:(NSDictionary *)annotation;
- (void)undo:(nullable id)sender;
- (void)redo:(nullable id)sender;
- (void)cancel:(nullable id)sender;
- (nullable NSData *)renderPNGData:(NSError **)error;
// Snapshot the current crop and pending edits without ending the editor's input
// transaction. Invalid fields or active IME composition return an error.
- (nullable NSData *)capturePNGData:(NSError **)error;
- (BOOL)copyToPasteboard:(NSPasteboard *)pasteboard error:(NSError **)error;
+ (BOOL)runSmokeInDirectory:(NSString *)directory error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
