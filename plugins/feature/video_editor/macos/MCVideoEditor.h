#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
@interface MCVideoEditor : NSObject <NSWindowDelegate>
@property (nonatomic, copy, nullable) void (^onClose)(void);
@property (nonatomic, copy, nullable) void (^onStateChange)(void);
@property (nonatomic, readonly) BOOL exporting;
- (nullable instancetype)initWithDraftDirectory:(NSURL *)directory error:(NSError **)error;
- (void)show;
// Retries durable draft persistence without closing the editor. A failed write
// keeps the in-memory document available and cancels application termination.
- (BOOL)prepareForTermination:(NSError **)error;
+ (BOOL)runSmokeInDirectory:(NSURL *)directory error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
