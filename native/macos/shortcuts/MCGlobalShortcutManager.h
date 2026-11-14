#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT const UInt32 MCCaptureHotKeySignature;
FOUNDATION_EXPORT const UInt32 MCCaptureHotKeyID;
FOUNDATION_EXPORT const UInt32 MCRecordHotKeyID;
FOUNDATION_EXPORT const UInt32 MCStopHotKeyID;

// Own this for the lifetime of the application, independently of settings.
// All lifecycle methods and callbacks run on the main thread.
@interface MCGlobalShortcutManager : NSObject
@property (nonatomic, readonly, getter=isRegistered) BOOL registered;
@property (nonatomic, readonly, copy, nullable) NSString *registrationError;
@property (nonatomic, copy, nullable) void (^onStatusChanged)(NSString * _Nullable error);
// Assign these before start. Unconnected actions are not registered.
@property (nonatomic, copy, nullable) void (^onRecord)(void);
@property (nonatomic, copy, nullable) void (^onStop)(void);
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults onCapture:(void (^)(void))onCapture;
- (void)start;
- (void)suspend;
- (void)resume;
- (void)invalidate;
@end

NS_ASSUME_NONNULL_END
