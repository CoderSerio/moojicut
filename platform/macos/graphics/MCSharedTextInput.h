#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
// System text input only. Field identity, validation, draft history and document
// publication belong to the shared owner. All calls must use the UI thread.
@interface MCSharedTextInputView : NSTextView
@property (nonatomic, copy, readonly, nullable) NSDictionary *fieldDescription;
// On acceptance the owner MUST synchronously apply the acknowledged field
// snapshot (new version) before returning YES. Reentrant retirement is allowed.
@property (nonatomic, copy, nullable) BOOL (^onEdit)(NSDictionary *fieldEvent);
@property (nonatomic, copy, nullable) void (^onAction)(NSString *action);
// Optional shared keyboard policy for a single-line field. Only unmarked
// Up/Down reach this callback; return YES when handled, NO for native navigation.
@property (nonatomic, copy, nullable) BOOL (^onKey)(NSDictionary *event);
// Pure preflight only: do not publish or destroy the input from this callback.
@property (nonatomic, copy, nullable) BOOL (^shouldResign)(void);
// Geometry is supplied in the containing surface's logical coordinate system.
// Same-token/version refreshes never replace text or disturb marked input.
- (BOOL)applyFieldDescription:(NSDictionary *)field;
- (void)performSharedUndo;
- (void)performSharedRedo;
- (void)invalidate;
@end
NS_ASSUME_NONNULL_END
