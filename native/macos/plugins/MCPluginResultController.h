#import <AppKit/AppKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface MCPluginResultController : NSObject <NSWindowDelegate>
@property (nonatomic, readonly) NSWindow *window;
@property (nonatomic, copy, nullable) void (^onClose)(void);
- (instancetype)initWithResult:(NSDictionary *)result pluginName:(NSString *)name;
- (void)show;
- (BOOL)copyToPasteboard:(NSPasteboard *)pasteboard;
- (void)close;
@end
NS_ASSUME_NONNULL_END
