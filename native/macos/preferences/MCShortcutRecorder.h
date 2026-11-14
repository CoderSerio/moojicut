#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
@interface MCShortcutRecorder : NSButton
@property (nonatomic, copy, nullable) NSDictionary *shortcut;
@property (nonatomic, readonly, getter=isRecording) BOOL recording;
// Local image-window controls may use unmodified keys; global controls may not.
@property (nonatomic) BOOL recordsPinShortcut;
@property (nonatomic, copy, nullable) BOOL (^onChange)(NSDictionary * _Nullable shortcut);
@property (nonatomic, copy, nullable) void (^onError)(NSString *message);
@property (nonatomic, copy, nullable) void (^onRecordingChanged)(BOOL recording);
- (void)beginRecording;
- (void)cancelRecording;
- (void)receiveKeyEvent:(NSEvent *)event;
@end
NS_ASSUME_NONNULL_END
