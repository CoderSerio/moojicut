#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
@interface MCImageEditorController : NSObject <NSWindowDelegate>
@property (nonatomic, readonly, nullable) NSWindow *window;
@property (nonatomic, readonly) NSDictionary *document;
@property (nonatomic, copy, nullable) void (^onClose)(void);
- (nullable instancetype)initWithPNGData:(NSData *)data error:(NSError **)error;
- (void)show;
- (BOOL)applyAnnotation:(NSDictionary *)annotation;
- (void)undo:(nullable id)sender;
- (void)redo:(nullable id)sender;
- (void)cancel:(nullable id)sender;
- (nullable NSData *)renderPNGData:(NSError **)error;
- (BOOL)copyToPasteboard:(NSPasteboard *)pasteboard error:(NSError **)error;
+ (BOOL)runSmokeInDirectory:(NSString *)directory error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
