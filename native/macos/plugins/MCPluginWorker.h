#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN
// Caps may be tightened from the defaults. Only wallTimeSeconds may be raised,
// up to 30 s. maxMemoryPages limits Wasm linear memory, not whole-process RSS;
// fuel limits guest instructions. The parent wall clock also covers startup,
// compilation and IPC, and forcibly kills a worker that ignores termination.
typedef struct {
    NSUInteger maxWasmBytes;
    NSUInteger maxInputBytes;
    NSUInteger maxOutputBytes;
    NSUInteger maxStderrBytes;
    NSTimeInterval wallTimeSeconds;
    uint64_t fuel;
    uint32_t timeoutMilliseconds;
    uint32_t maxMemoryPages;
} MCPluginWorkerLimits;
FOUNDATION_EXPORT MCPluginWorkerLimits MCPluginWorkerDefaultLimits(void);
FOUNDATION_EXPORT NSString *const MCPluginWorkerErrorDomain;
typedef NS_ENUM(NSInteger, MCPluginWorkerErrorCode) {
    MCPluginWorkerInvalidRequest = 1,
    MCPluginWorkerLaunchFailed = 2,
    MCPluginWorkerTimedOut = 3,
    MCPluginWorkerCancelled = 4,
    MCPluginWorkerOutputLimitExceeded = 5,
    MCPluginWorkerExecutionFailed = 6,
    MCPluginWorkerCommunicationFailed = 7,
};

// One process per invocation. executableURL must be a host-owned bundled helper,
// never a path supplied by a plugin. Completion runs once on the main queue,
// after the subprocess has terminated and its pipes have been drained/closed.
@interface MCPluginWorker : NSObject
@property (atomic, readonly, getter=isRunning) BOOL running;
+ (instancetype)startWithExecutableURL:(NSURL *)executableURL
                             wasmData:(NSData *)wasm
                            inputData:(NSData *)input
                               limits:(MCPluginWorkerLimits)limits
                           completion:(void (^)(NSData * _Nullable output, NSError * _Nullable error))completion;
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
