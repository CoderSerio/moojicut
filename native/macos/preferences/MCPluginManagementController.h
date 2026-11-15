#import <AppKit/AppKit.h>
@class MCToolRegistryStore;

NS_ASSUME_NONNULL_BEGIN
@interface MCPluginManagementController : NSViewController
@property (nonatomic, strong, nullable) MCToolRegistryStore *toolRegistryStore;
- (instancetype)initWithStore:(nullable MCToolRegistryStore *)store;
// The preferences window calls this before releasing its content views.
- (void)invalidate;
@end
NS_ASSUME_NONNULL_END
