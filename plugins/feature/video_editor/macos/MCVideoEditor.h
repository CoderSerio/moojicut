#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
@interface MCVideoEditor : NSObject <NSWindowDelegate>
@property (nonatomic, copy, nullable) void (^onClose)(void);
@property (nonatomic, copy, nullable) void (^onStateChange)(void);
@property (nonatomic, readonly) BOOL exporting;
// Only visible editing content is eligible for a desktop screenshot.
@property (nonatomic, readonly) NSSet<NSNumber *> *visibleWindowNumbers;
- (nullable instancetype)initWithDraftDirectory:(NSURL *)directory error:(NSError **)error;
- (void)show;
// Retries durable draft persistence without closing the editor. A failed write
// keeps the in-memory document available and cancels application termination.
- (BOOL)prepareForTermination:(NSError **)error;
// Completion follows root CLOSE_MEDIA and all actual native cleanup; errors keep edits open.
- (void)requestTermination:(void (^)(NSError * _Nullable error))completion;
+ (BOOL)runSmokeInDirectory:(NSURL *)directory error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
