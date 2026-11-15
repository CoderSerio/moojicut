#import <AppKit/AppKit.h>
@class MCToolRegistryStore, MCUserPluginManager;

NS_ASSUME_NONNULL_BEGIN
@interface MCPluginManagementController : NSViewController
@property (nonatomic, strong, nullable) MCToolRegistryStore *toolRegistryStore;
@property (nonatomic, strong, nullable) MCUserPluginManager *userPluginManager;
- (instancetype)initWithStore:(nullable MCToolRegistryStore *)store;
// The preferences window calls this before releasing its content views.
- (void)invalidate;
@end
NS_ASSUME_NONNULL_END
