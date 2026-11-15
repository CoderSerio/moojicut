#import "MCPluginWorker.h"
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <unistd.h>

NSString *const MCPluginWorkerErrorDomain = @"dev.moojicut.plugin-worker";
MCPluginWorkerLimits MCPluginWorkerDefaultLimits(void) {
    return (MCPluginWorkerLimits){4*1024*1024,64*1024,256*1024,16*1024,5,50000000,1000,1024};
}
static NSError *MCWorkerError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:MCPluginWorkerErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
static void MCAppend32(NSMutableData *data, uint32_t value) {
    uint8_t bytes[] = {value>>24,value>>16,value>>8,value}; [data appendBytes:bytes length:4];
}
@interface MCPluginWorker ()
@property (atomic, readwrite, getter=isRunning) BOOL running;
@property dispatch_queue_t queue;
@property NSTask *task;
@property NSPipe *inputPipe, *outputPipe, *errorPipe;
@property dispatch_source_t outputSource, errorSource, inputSource, deadline;
@property NSMutableData *output, *diagnostics;
@property NSData *payload;
@property NSUInteger written;
@property MCPluginWorkerLimits limits;
@property NSError *failure;
@property BOOL launchPending, exited, outputEOF, errorEOF, inputClosed, inputClosing, finished;
@property (copy) void (^completion)(NSData *, NSError *);
@property MCPluginWorker *lifetime;
@end
@implementation MCPluginWorker
+ (instancetype)startWithExecutableURL:(NSURL *)url wasmData:(NSData *)wasm inputData:(NSData *)input
                               limits:(MCPluginWorkerLimits)limits completion:(void (^)(NSData *, NSError *))completion {
    MCPluginWorker *worker = [self new];
    worker.queue = dispatch_queue_create("dev.moojicut.plugin-worker", DISPATCH_QUEUE_SERIAL);
    worker.running = YES; worker.limits = limits; worker.completion = completion; worker.lifetime = worker;
    MCPluginWorkerLimits hard = MCPluginWorkerDefaultLimits();
    BOOL valid = url.isFileURL && limits.maxWasmBytes > 0 && limits.maxWasmBytes <= hard.maxWasmBytes &&
        limits.maxInputBytes > 0 && limits.maxInputBytes <= hard.maxInputBytes &&
        limits.maxOutputBytes > 0 && limits.maxOutputBytes <= hard.maxOutputBytes &&
        limits.maxStderrBytes > 0 && limits.maxStderrBytes <= hard.maxStderrBytes &&
        isfinite(limits.wallTimeSeconds) && limits.wallTimeSeconds > 0 && limits.wallTimeSeconds <= 30 &&
        limits.fuel > 0 && limits.fuel <= hard.fuel && limits.timeoutMilliseconds > 0 &&
        limits.timeoutMilliseconds <= hard.timeoutMilliseconds && limits.maxMemoryPages > 0 &&
        limits.maxMemoryPages <= hard.maxMemoryPages && wasm.length > 0 && wasm.length <= limits.maxWasmBytes &&
        input.length > 0 && input.length <= limits.maxInputBytes;
    if (!valid) {
        dispatch_async(worker.queue, ^{ worker.failure = MCWorkerError(MCPluginWorkerInvalidRequest,@"插件请求或执行限额无效。"); [worker finish]; });
        return worker;
    }
    NSMutableData *payload = [NSMutableData dataWithBytes:"MOOJIW1\0" length:8];
    MCAppend32(payload,(uint32_t)wasm.length); MCAppend32(payload,(uint32_t)input.length);
    MCAppend32(payload,limits.timeoutMilliseconds); MCAppend32(payload,limits.maxMemoryPages);
    MCAppend32(payload,(uint32_t)limits.maxOutputBytes);
    MCAppend32(payload,(uint32_t)(limits.fuel>>32)); MCAppend32(payload,(uint32_t)limits.fuel);
    [payload appendData:wasm]; [payload appendData:input]; worker.payload = payload;
    dispatch_async(worker.queue, ^{ [worker launch:url]; });
    return worker;
}
- (void)launch:(NSURL *)url {
    if (self.failure || self.finished) { [self finish]; return; }
    self.output = [NSMutableData data]; self.diagnostics = [NSMutableData data];
    self.inputPipe = [NSPipe pipe]; self.outputPipe = [NSPipe pipe]; self.errorPipe = [NSPipe pipe];
    self.task = [NSTask new]; self.task.executableURL = url; self.task.arguments = @[];
    // Do not inherit DYLD_*, EXTISM_*, credentials or the user's environment.
    self.task.environment = @{@"PATH":@"/usr/bin:/bin", @"LANG":@"en_US.UTF-8"};
    self.task.currentDirectoryURL = [NSURL fileURLWithPath:@"/" isDirectory:YES];
    self.task.standardInput = self.inputPipe; self.task.standardOutput = self.outputPipe; self.task.standardError = self.errorPipe;
    __weak MCPluginWorker *weakSelf = self;
    self.task.terminationHandler = ^(NSTask *task) {
        MCPluginWorker *owner = weakSelf; if (!owner) return;
        dispatch_async(owner.queue, ^{ (void)task; owner.exited = YES; [owner maybeFinish]; });
    };
    self.deadline = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,self.queue);
    dispatch_source_set_timer(self.deadline,dispatch_time(DISPATCH_TIME_NOW,(int64_t)(self.limits.wallTimeSeconds*NSEC_PER_SEC)),DISPATCH_TIME_FOREVER,0);
    dispatch_source_set_event_handler(self.deadline, ^{ [weakSelf stop:MCWorkerError(MCPluginWorkerTimedOut,@"插件执行超时，已停止工作进程。")]; });
    dispatch_resume(self.deadline);
    self.launchPending = YES;
    NSTask *task = self.task;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NSError *error = nil; BOOL launched = [task launchAndReturnError:&error];
        dispatch_async(self.queue, ^{
            self.launchPending = NO;
            [self.inputPipe.fileHandleForReading closeAndReturnError:NULL];
            [self.outputPipe.fileHandleForWriting closeAndReturnError:NULL];
            [self.errorPipe.fileHandleForWriting closeAndReturnError:NULL];
            if (!launched) {
                self.failure = self.failure ?: MCWorkerError(MCPluginWorkerLaunchFailed,error.localizedDescription ?: @"无法启动插件工作进程。");
                [self finish]; return;
            }
            [self startPipes];
            if (self.failure) [self terminateProcess];
            [self maybeFinish];
        });
    });
}
- (void)startPipes {
    int output = self.outputPipe.fileHandleForReading.fileDescriptor, diagnostic = self.errorPipe.fileHandleForReading.fileDescriptor;
    int input = self.failure ? -1 : self.inputPipe.fileHandleForWriting.fileDescriptor;
    BOOL configured = fcntl(output,F_SETFL,fcntl(output,F_GETFL)|O_NONBLOCK) == 0 &&
        fcntl(diagnostic,F_SETFL,fcntl(diagnostic,F_GETFL)|O_NONBLOCK) == 0 &&
        (input < 0 || (fcntl(input,F_SETFL,fcntl(input,F_GETFL)|O_NONBLOCK) == 0 && fcntl(input,F_SETNOSIGPIPE,1) == 0));
    if (!configured) {
        self.outputEOF = self.errorEOF = YES;
        [self stop:MCWorkerError(MCPluginWorkerCommunicationFailed,@"无法配置插件通信管道。")]; return;
    }
    __weak MCPluginWorker *weakSelf = self;
    self.outputSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,output,0,self.queue);
    self.errorSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,diagnostic,0,self.queue);
    if (input >= 0) self.inputSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE,input,0,self.queue);
    NSFileHandle *outputHandle = self.outputPipe.fileHandleForReading, *errorHandle = self.errorPipe.fileHandleForReading;
    dispatch_source_set_cancel_handler(self.outputSource, ^{ [outputHandle closeAndReturnError:NULL]; weakSelf.outputEOF = YES; [weakSelf maybeFinish]; });
    dispatch_source_set_cancel_handler(self.errorSource, ^{ [errorHandle closeAndReturnError:NULL]; weakSelf.errorEOF = YES; [weakSelf maybeFinish]; });
    dispatch_source_set_event_handler(self.outputSource, ^{ [weakSelf readPipe:NO]; });
    dispatch_source_set_event_handler(self.errorSource, ^{ [weakSelf readPipe:YES]; });
    if (self.inputSource) {
        NSFileHandle *inputHandle = self.inputPipe.fileHandleForWriting;
        dispatch_source_set_cancel_handler(self.inputSource, ^{ [inputHandle closeAndReturnError:NULL]; weakSelf.inputClosed = YES; weakSelf.inputClosing = NO; [weakSelf maybeFinish]; });
        dispatch_source_set_event_handler(self.inputSource, ^{ [weakSelf writeInput]; });
        dispatch_resume(self.inputSource);
    }
    dispatch_resume(self.outputSource); dispatch_resume(self.errorSource);
}
- (void)writeInput {
    if (self.finished || !self.inputSource || !self.payload) return;
    if (self.failure) { [self closeInput]; return; }
    NSUInteger remaining = self.payload.length - self.written;
    ssize_t n = write(self.inputPipe.fileHandleForWriting.fileDescriptor,(const uint8_t *)self.payload.bytes+self.written,MIN(remaining,65536));
    if (n > 0) self.written += (NSUInteger)n;
    else if (n < 0 && errno != EAGAIN && errno != EINTR) {
        [self stop:MCWorkerError(MCPluginWorkerCommunicationFailed,@"插件工作进程未能读取请求。")]; return;
    }
    if (self.written == self.payload.length) [self closeInput];
}
- (void)closeInput {
    if (self.inputSource) { self.inputClosing = YES; dispatch_source_cancel(self.inputSource); self.inputSource = nil; }
    else if (!self.inputClosed && !self.inputClosing) { [self.inputPipe.fileHandleForWriting closeAndReturnError:NULL]; self.inputClosed = YES; }
    self.payload = nil;
}
- (void)readPipe:(BOOL)diagnostic {
    if (self.finished || (diagnostic ? !self.errorSource : !self.outputSource)) return;
    NSFileHandle *handle = diagnostic ? self.errorPipe.fileHandleForReading : self.outputPipe.fileHandleForReading;
    NSMutableData *buffer = diagnostic ? self.diagnostics : self.output;
    NSUInteger limit = diagnostic ? self.limits.maxStderrBytes : self.limits.maxOutputBytes;
    // Bound each readiness callback so an output flood cannot starve the timer.
    for (NSUInteger chunk = 0; chunk < 16; chunk++) {
        uint8_t bytes[4096]; ssize_t n = read(handle.fileDescriptor,bytes,sizeof(bytes));
        if (n > 0) {
            if ((NSUInteger)n > limit-buffer.length) {
                [self stop:MCWorkerError(MCPluginWorkerOutputLimitExceeded,diagnostic ? @"插件诊断输出超过上限。" : @"插件输出超过上限。")];
            } else if (!self.failure) [buffer appendBytes:bytes length:(NSUInteger)n];
        } else if (n == 0 || (errno != EAGAIN && errno != EINTR)) {
            if (n < 0) [self stop:MCWorkerError(MCPluginWorkerCommunicationFailed,@"插件通信管道读取失败。")];
            if (diagnostic) { dispatch_source_cancel(self.errorSource); self.errorSource = nil; }
            else { dispatch_source_cancel(self.outputSource); self.outputSource = nil; }
            return;
        } else if (errno == EAGAIN) return;
    }
}
- (void)stop:(NSError *)error {
    if (self.finished) return;
    if (self.failure) return;
    self.failure = error;
    [self closeInput]; [self terminateProcess];
    if (!self.task && !self.launchPending) [self finish];
}
- (void)terminateProcess {
    if (self.task.running) [self.task terminate];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),self.queue, ^{
        if (!self.finished && self.task.running) kill(self.task.processIdentifier,SIGKILL);
    });
}
- (void)cancel { dispatch_async(self.queue, ^{ [self stop:MCWorkerError(MCPluginWorkerCancelled,@"插件执行已取消。")]; }); }
- (void)maybeFinish {
    if (!self.launchPending && self.exited && self.outputEOF && self.errorEOF && self.inputClosed) {
        if (!self.failure && (self.task.terminationReason != NSTaskTerminationReasonExit || self.task.terminationStatus != 0)) {
            NSString *diagnostic = [[NSString alloc] initWithData:self.diagnostics encoding:NSUTF8StringEncoding];
            if (diagnostic.length > 1024) diagnostic = [diagnostic substringToIndex:1024];
            self.failure = MCWorkerError(MCPluginWorkerExecutionFailed,diagnostic.length ? diagnostic : @"插件工作进程执行失败。");
        }
        [self finish];
    }
}
- (void)finish {
    if (self.finished) return;
    self.finished = YES; self.running = NO;
    if (self.deadline) { dispatch_source_cancel(self.deadline); self.deadline = nil; }
    if (self.outputSource) { dispatch_source_cancel(self.outputSource); self.outputSource = nil; }
    if (self.errorSource) { dispatch_source_cancel(self.errorSource); self.errorSource = nil; }
    [self closeInput];
    for (NSPipe *pipe in @[self.inputPipe ?: (id)NSNull.null,self.outputPipe ?: (id)NSNull.null,self.errorPipe ?: (id)NSNull.null]) {
        if (![pipe isKindOfClass:NSPipe.class]) continue;
        [pipe.fileHandleForReading closeAndReturnError:NULL]; [pipe.fileHandleForWriting closeAndReturnError:NULL];
    }
    self.task.terminationHandler = nil;
    void (^completion)(NSData *,NSError *) = self.completion;
    NSData *result = self.failure ? nil : [self.output copy]; NSError *error = self.failure;
    self.completion = nil; self.lifetime = nil;
    dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(result,error); });
}
@end
