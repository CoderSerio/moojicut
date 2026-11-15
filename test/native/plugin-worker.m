#import <Foundation/Foundation.h>
#import "../../native/macos/plugins/MCPluginWorker.h"
#include <signal.h>
#include <unistd.h>

static void Check(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr,"FAIL: %s\n",message.UTF8String); exit(1); }
}
static void AppendByte(NSMutableData *data, uint8_t value) { [data appendBytes:&value length:1]; }
static void U32(NSMutableData *data, uint32_t value) {
    do { uint8_t part=value&127; value>>=7; AppendByte(data,part|(value?128:0)); } while(value);
}
static void Name(NSMutableData *data, NSString *name) {
    NSData *bytes=[name dataUsingEncoding:NSUTF8StringEncoding]; U32(data,(uint32_t)bytes.length); [data appendData:bytes];
}
static void Section(NSMutableData *data, uint8_t id, NSData *payload) { AppendByte(data,id); U32(data,(uint32_t)payload.length); [data appendData:payload]; }
static NSData *Bytes(const uint8_t *data, NSUInteger length) { return [NSData dataWithBytes:data length:length]; }
#define BYTES(...) Bytes((uint8_t[]){__VA_ARGS__}, sizeof((uint8_t[]){__VA_ARGS__}))

// Tiny real plain-Wasm fixtures. The successful module copies its input through
// precisely the six PDK imports allowed by the host, not an in-process mock.
static NSData *Module(NSString *mode) {
    NSMutableData *wasm=[NSMutableData dataWithBytes:"\0asm\1\0\0\0" length:8];
    Section(wasm,1,BYTES(8, 0x60,0,1,0x7f, 0x60,1,0x7e,1,0x7e, 0x60,2,0x7e,0x7f,0,
        0x60,2,0x7e,0x7e,0, 0x60,0,1,0x7e, 0x60,1,0x7e,1,0x7f, 0x60,1,0x7e,0, 0x60,0,0));
    NSMutableData *imports=[NSMutableData data]; U32(imports,6);
    NSArray *names=@[@"alloc",@"store_u8",@"output_set",@"input_length",@"input_load_u8",@"error_set"];
    for (NSUInteger i=0;i<names.count;i++) {
        Name(imports,[mode isEqual:@"wasi"] ? @"wasi_snapshot_preview1" : @"extism:host/env");
        Name(imports,[mode isEqual:@"unknown"] && i==0 ? @"config_get" : names[i]);
        AppendByte(imports,[mode isEqual:@"nonfunction"] && i==0 ? 1 : 0); U32(imports,(uint32_t)i+1);
    }
    Section(wasm,2,imports);
    BOOL start=[mode isEqual:@"start-loop"], isVoid=[mode isEqual:@"void"];
    Section(wasm,3,start ? BYTES(2,0,7) : isVoid ? BYTES(1,7) : BYTES(1,0));
    if ([mode isEqual:@"memory"]) Section(wasm,5,BYTES(1,0,0x81,0x08)); // minimum 1025 pages
    NSMutableData *exports=[NSMutableData data]; U32(exports,1);
    Name(exports,[mode isEqual:@"missing"] ? @"other" : @"mooji_run"); AppendByte(exports,0); U32(exports,[mode isEqual:@"imported"] ? 0 : 6);
    Section(wasm,7,exports);
    if (start) Section(wasm,8,BYTES(7));
    NSData *body=isVoid ? BYTES(0,0x0b) : BYTES(
        1,3,0x7e,                      // three i64 locals: length, address, index
        0x10,3,0x21,0,0x20,0,0x10,0,0x21,1,0x42,0,0x21,2,
        0x02,0x40,0x03,0x40,           // block / loop
        0x20,2,0x20,0,0x5a,0x0d,1,    // break when index >= input length
        0x20,1,0x20,2,0x7c,0x20,2,0x10,4,0x10,1,
        0x20,2,0x42,1,0x7c,0x21,2,0x0c,0,0x0b,0x0b,
        0x20,1,0x20,0,0x10,2,0x41,0,0x0b);
    NSMutableData *code=[NSMutableData data]; U32(code,start?2:1); U32(code,(uint32_t)body.length); [code appendData:body];
    if (start) { NSData *loop=BYTES(0,0x03,0x40,0x0c,0,0x0b,0x0b); U32(code,(uint32_t)loop.length); [code appendData:loop]; }
    Section(wasm,10,code);
    if ([mode isEqual:@"section-order"]) Section(wasm,1,BYTES(0));
    return wasm;
}
static NSData *Run(NSURL *executable, NSData *wasm, NSData *input, MCPluginWorkerLimits limits,
                   double cancelAfter, NSError **failure) {
    __block BOOL done=NO; __block NSUInteger calls=0;
    __block NSData *result=nil; __block NSError *error=nil; __block MCPluginWorker *worker=nil;
    worker=[MCPluginWorker startWithExecutableURL:executable wasmData:wasm inputData:input limits:limits completion:^(NSData *output,NSError *problem) {
        calls++; Check(NSThread.isMainThread,@"completion must use the main queue");
        Check(!worker.running,@"completion must follow subprocess cleanup");
        result=output; error=problem; done=YES;
    }];
    if (cancelAfter>=0) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(cancelAfter*NSEC_PER_SEC)),dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{ [worker cancel]; });
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:8];
    while (!done && deadline.timeIntervalSinceNow>0) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    Check(done,@"worker did not complete within fixture deadline");
    // Cancellation after completion is harmless and must not call back twice.
    [worker cancel];
    NSDate *settle=[NSDate dateWithTimeIntervalSinceNow:0.02];
    while(settle.timeIntervalSinceNow>0) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:settle];
    Check(calls==1,@"completion must be delivered exactly once");
    if (failure) *failure=error; return result;
}
static NSURL *Stub(NSURL *directory, NSString *name, NSString *source) {
    NSURL *url=[directory URLByAppendingPathComponent:name]; NSError *error=nil;
    Check([[NSFileManager defaultManager] linkItemAtPath:source toPath:url.path error:&error],error.localizedDescription ?: @"create child fixture"); return url;
}
int main(int argc,const char **argv) {
    @autoreleasepool {
        NSString *name=[[NSString stringWithUTF8String:argv[0]] lastPathComponent];
        if ([name hasPrefix:@"worker-"]) {
            signal(SIGTERM,SIG_IGN);
            if ([name isEqual:@"worker-stall"]) { for (;;) pause(); }
            if ([name isEqual:@"worker-exit"]) return 17;
            uint8_t bytes[4096]; memset(bytes,'x',sizeof(bytes));
            int fd=[name isEqual:@"worker-stderr"] ? STDERR_FILENO : STDOUT_FILENO;
            while(write(fd,bytes,sizeof(bytes))>0) {} return 0;
        }
        Check(argc==2,@"usage: plugin-worker-test /absolute/path/MoojiPluginWorker");
        NSURL *executable=[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
        NSData *input=[@"{\"apiVersion\":1,\"invocationId\":\"fixture\",\"toolId\":\"describe\",\"capture\":{\"width\":1440,\"height\":900,\"format\":\"png\",\"revision\":0}}" dataUsingEncoding:NSUTF8StringEncoding];
        MCPluginWorkerLimits limits=MCPluginWorkerDefaultLimits(); NSError *error=nil;
        NSData *output=Run(executable,Module(@"echo"),input,limits,-1,&error);
        Check(!error && [output isEqual:input],[NSString stringWithFormat:@"real Extism roundtrip: %@",error]);
        for (NSString *mode in @[@"void",@"missing",@"imported",@"wasi",@"unknown",@"nonfunction",@"section-order"]) {
            Run(executable,Module(mode),input,limits,-1,&error);
            Check(error.code==MCPluginWorkerExecutionFailed && [error.localizedDescription containsString:@"Unsupported Wasm"],[NSString stringWithFormat:@"reject %@: %@",mode,error]);
        }
        NSMutableData *overflow=[NSMutableData dataWithBytes:"\0asm\1\0\0\0" length:8]; [overflow appendData:BYTES(1,0x80,0x80,0x80,0x80,0x10)];
        Run(executable,overflow,input,limits,-1,&error); Check(error.code==MCPluginWorkerExecutionFailed,@"reject LEB overflow");
        NSData *valid=Module(@"echo");
        Run(executable,[valid subdataWithRange:NSMakeRange(0,valid.length-1)],input,limits,-1,&error); Check(error.code==MCPluginWorkerExecutionFailed,@"reject section truncation");
        MCPluginWorkerLimits small=limits; small.maxOutputBytes=8;
        Run(executable,valid,input,small,-1,&error); Check(error.code==MCPluginWorkerExecutionFailed && [error.localizedDescription containsString:@"output limit"],@"enforce runtime output cap");
        small=limits; small.fuel=10000;
        Run(executable,Module(@"start-loop"),input,small,-1,&error); Check(error.code==MCPluginWorkerExecutionFailed && [error.localizedDescription containsString:@"fuel"],[NSString stringWithFormat:@"bound start-section work: %@",error]);
        Run(executable,Module(@"memory"),input,limits,-1,&error); Check(error.code==MCPluginWorkerExecutionFailed,@"enforce memory pages");
        Run([NSURL fileURLWithPath:@"/nonexistent/MoojiPluginWorker"],valid,input,limits,-1,&error); Check(error.code==MCPluginWorkerLaunchFailed,@"report startup failure");
        small=limits; small.maxInputBytes=1;
        Run(executable,valid,input,small,-1,&error); Check(error.code==MCPluginWorkerInvalidRequest,@"reject parent request before spawning");
        NSURL *directory=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
        Check([[NSFileManager defaultManager] createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:NULL],@"create child fixture directory");
        NSString *source=[[[NSProcessInfo processInfo] arguments][0] stringByStandardizingPath];
        NSURL *stall=Stub(directory,@"worker-stall",source);
        NSData *large=[NSMutableData dataWithLength:limits.maxWasmBytes];
        small=limits; small.wallTimeSeconds=0.08;
        NSTimeInterval started=NSProcessInfo.processInfo.systemUptime;
        Run(stall,large,input,small,-1,&error);
        Check(error.code==MCPluginWorkerTimedOut && NSProcessInfo.processInfo.systemUptime-started<2,@"wall deadline covers startup and a blocked input pipe, escalates SIGTERM");
        Run(stall,large,input,limits,0.04,&error); Check(error.code==MCPluginWorkerCancelled,@"cancel and reap a stuck process");
        for (NSString *kind in @[@"worker-stdout",@"worker-stderr"]) {
            Run(Stub(directory,kind,source),valid,input,limits,-1,&error); Check(error.code==MCPluginWorkerOutputLimitExceeded,[NSString stringWithFormat:@"bound %@ pipe output",kind]);
        }
        Run(Stub(directory,@"worker-exit",source),large,input,limits,-1,&error); Check(error!=nil,@"early child exit must not SIGPIPE the parent");
        Check([[NSFileManager defaultManager] removeItemAtURL:directory error:NULL],@"remove child fixture directory");
        printf("Plugin worker: Extism roundtrip, strict Wasm ABI, fuel/memory/output limits, deadline, cancellation and pipe cleanup passed.\n");
    }
    return 0;
}
