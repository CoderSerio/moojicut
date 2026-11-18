#import "MCPluginWorker.h"
#include "platform/shared/plugin_host/worker_process.h"
#include <math.h>

NSString *const MCPluginWorkerErrorDomain = @"dev.moojicut.plugin-worker";
MCPluginWorkerLimits MCPluginWorkerDefaultLimits(void) {
    return (MCPluginWorkerLimits){MC_WASM_MAX_MODULE_BYTES,MC_WASM_MAX_INPUT_BYTES,MC_WASM_MAX_OUTPUT_BYTES,
        MC_PLUGIN_MAX_STDERR_BYTES,MC_PLUGIN_DEFAULT_WALL_SECONDS,MC_WASM_MAX_FUEL,MC_WASM_MAX_TIMEOUT_MS,MC_WASM_MAX_MEMORY_PAGES};
}
static NSError *MCWorkerError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:MCPluginWorkerErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
static NSError *MCProcessError(MCPluginProcessStatus status, const MCPluginProcessResult *result) {
    switch (status) {
        case MC_PLUGIN_PROCESS_OK: return nil;
        case MC_PLUGIN_PROCESS_CANCELLED:
            return MCWorkerError(MCPluginWorkerCancelled,@"插件执行已取消。");
        case MC_PLUGIN_PROCESS_TIMED_OUT:
            return MCWorkerError(MCPluginWorkerTimedOut,@"插件执行超时，已停止工作进程。");
        case MC_PLUGIN_PROCESS_LAUNCH_FAILED: {
            NSString *detail = result->system_error ?
                [NSError errorWithDomain:NSPOSIXErrorDomain code:result->system_error userInfo:nil].localizedDescription : nil;
            return MCWorkerError(MCPluginWorkerLaunchFailed,detail ?: @"无法启动插件工作进程。");
        }
        case MC_PLUGIN_PROCESS_IO_FAILED:
            return MCWorkerError(MCPluginWorkerCommunicationFailed,@"插件通信管道读取或写入失败。");
        case MC_PLUGIN_PROCESS_LIMIT_EXCEEDED:
            return MCWorkerError(MCPluginWorkerOutputLimitExceeded,@"插件输出或诊断输出超过上限。");
        case MC_PLUGIN_PROCESS_EXECUTION_FAILED: {
            NSString *diagnostic = [[NSString alloc] initWithBytes:result->diagnostics length:result->diagnostics_size encoding:NSUTF8StringEncoding];
            if (diagnostic.length > 1024) diagnostic = [diagnostic substringToIndex:1024];
            return MCWorkerError(MCPluginWorkerExecutionFailed,diagnostic.length ? diagnostic : @"插件工作进程执行失败。");
        }
        case MC_PLUGIN_PROCESS_RUNNING: break;
    }
    return MCWorkerError(MCPluginWorkerCommunicationFailed,@"插件工作进程返回了无效状态。");
}

@interface MCPluginWorker ()
@property (atomic, readwrite, getter=isRunning) BOOL running;
@property dispatch_queue_t queue;
@property dispatch_source_t pollTimer;
@property (nonatomic) MCPluginProcess *process;
@property NSData *output;
@property NSError *failure;
@property BOOL finished;
@property (copy) void (^completion)(NSData *, NSError *);
@property MCPluginWorker *lifetime;
@end

@implementation MCPluginWorker
+ (instancetype)startWithExecutableURL:(NSURL *)url wasmData:(NSData *)wasm inputData:(NSData *)input
                               limits:(MCPluginWorkerLimits)limits completion:(void (^)(NSData *, NSError *))completion {
    MCPluginWorker *worker = [self new];
    worker.queue = dispatch_queue_create("dev.moojicut.plugin-worker", DISPATCH_QUEUE_SERIAL);
    worker.running = YES; worker.completion = completion; worker.lifetime = worker;
    MCPluginWorkerLimits hard = MCPluginWorkerDefaultLimits();
    MCPluginWireRequest wire = {
        .wasm_size = wasm.length, .input_size = input.length, .max_output_bytes = limits.maxOutputBytes,
        .fuel = limits.fuel, .timeout_ms = limits.timeoutMilliseconds, .max_memory_pages = limits.maxMemoryPages
    };
    BOOL valid = url.isFileURL && url.path.isAbsolutePath && url.path.UTF8String &&
        limits.maxWasmBytes > 0 && limits.maxWasmBytes <= hard.maxWasmBytes &&
        limits.maxInputBytes > 0 && limits.maxInputBytes <= hard.maxInputBytes &&
        limits.maxStderrBytes > 0 && limits.maxStderrBytes <= hard.maxStderrBytes &&
        isfinite(limits.wallTimeSeconds) && limits.wallTimeSeconds > 0 && limits.wallTimeSeconds <= MC_PLUGIN_MAX_WALL_SECONDS &&
        wasm.length <= limits.maxWasmBytes && input.length <= limits.maxInputBytes &&
        mc_plugin_wire_request_valid(&wire);
    if (!valid) {
        dispatch_async(worker.queue, ^{
            worker.failure = MCWorkerError(MCPluginWorkerInvalidRequest,@"插件请求或执行限额无效。");
            [worker finish];
        });
        return worker;
    }
    // Freeze mutable caller data before returning, as the old payload builder
    // did. All C handle operations then belong to this same serial queue.
    NSData *wasmCopy = [wasm copy], *inputCopy = [input copy];
    NSString *path = [url.path copy];
    dispatch_async(worker.queue, ^{
        MCPluginProcessRequest request = {
            .executable = path.UTF8String, .wasm = wasmCopy.bytes, .input = inputCopy.bytes,
            .wire = wire, .max_stderr_bytes = limits.maxStderrBytes,
            .wall_ms = (uint32_t)ceil(limits.wallTimeSeconds * 1000.0)
        };
        worker.process = mc_plugin_process_start(&request);
        if (!worker.process) {
            worker.failure = MCWorkerError(MCPluginWorkerLaunchFailed,@"无法创建插件工作进程。");
            [worker finish];
            return;
        }
        __weak MCPluginWorker *weakWorker = worker;
        worker.pollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,worker.queue);
        dispatch_source_set_timer(worker.pollTimer,DISPATCH_TIME_NOW,10 * NSEC_PER_MSEC,NSEC_PER_MSEC);
        dispatch_source_set_event_handler(worker.pollTimer, ^{ @autoreleasepool { [weakWorker poll]; } });
        dispatch_resume(worker.pollTimer);
    });
    return worker;
}
- (void)poll {
    if (self.finished || !self.process) return;
    MCPluginProcessResult result = {0};
    MCPluginProcessStatus status = mc_plugin_process_poll(self.process,&result);
    if (status == MC_PLUGIN_PROCESS_RUNNING) return;
    // Borrowed adapter bytes must be copied before close. A terminal result
    // already guarantees child reaping and complete pipe teardown.
    self.failure = MCProcessError(status,&result);
    if (!self.failure) self.output = [NSData dataWithBytes:result.output length:result.output_size];
    if (!mc_plugin_process_close(self.process)) return;
    self.process = NULL;
    [self finish];
}
- (void)cancel {
    dispatch_async(self.queue, ^{
        if (!self.finished && self.process) {
            mc_plugin_process_cancel(self.process);
            [self poll];
        }
    });
}
- (void)finish {
    if (self.finished) return;
    self.finished = YES; self.running = NO;
    if (self.pollTimer) { dispatch_source_cancel(self.pollTimer); self.pollTimer = nil; }
    void (^completion)(NSData *,NSError *) = self.completion;
    NSData *result = self.failure ? nil : self.output; NSError *error = self.failure;
    self.completion = nil; self.lifetime = nil;
    dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(result,error); });
}
@end
