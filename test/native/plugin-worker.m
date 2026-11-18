#import <Foundation/Foundation.h>
#import "../../native/macos/plugins/MCPluginWorker.h"
#include "platform/shared/plugin_host/worker_protocol.h"
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

static void WireProtocol(void) {
    // Fixed legacy bytes, independent of either the encoder or decoder.
    NSData *golden=BYTES('M','O','O','J','I','W','1',0,
        0,1,2,3, 0,0,3,4, 0,0,3,0xe8, 0,0,4,0, 0,2,3,4, 0,0,0,0, 2,0xfa,0xf0,0x80);
    MCPluginWireRequest request={.wasm_size=0x010203,.input_size=0x0304,.max_output_bytes=0x020304,
        .fuel=50000000,.timeout_ms=1000,.max_memory_pages=1024};
    uint8_t header[MC_PLUGIN_WIRE_HEADER_BYTES];
    Check(mc_plugin_wire_encode(&request,header,sizeof(header))==MC_PLUGIN_WIRE_OK &&
          [Bytes(header,sizeof(header)) isEqual:golden],@"shared encoder preserves exact legacy wire bytes");
    MCPluginWireRequest decoded={0};
    Check(mc_plugin_wire_decode(golden.bytes,golden.length,&decoded)==MC_PLUGIN_WIRE_OK &&
          decoded.wasm_size==0x010203 && decoded.input_size==0x0304 && decoded.max_output_bytes==0x020304 &&
          decoded.fuel==50000000 && decoded.timeout_ms==1000 && decoded.max_memory_pages==1024,
          @"shared decoder reads the fixed legacy vector");
    request.wasm_size=SIZE_MAX;
    Check(mc_plugin_wire_encode(&request,header,sizeof(header))==MC_PLUGIN_WIRE_INVALID_LIMITS &&
          [Bytes(header,sizeof(header)) isEqual:golden],@"oversized host length is rejected before u32 narrowing or output mutation");
    NSMutableData *invalid=[golden mutableCopy]; ((uint8_t *)invalid.mutableBytes)[28]=1;
    Check(mc_plugin_wire_decode(invalid.bytes,invalid.length,&decoded)==MC_PLUGIN_WIRE_INVALID_LIMITS && decoded.fuel==50000000,
          @"high fuel word cannot overflow into an allowed limit and rejected decode leaves output intact");
    Check(mc_plugin_wire_decode(golden.bytes,golden.length-1,&decoded)==MC_PLUGIN_WIRE_INVALID_HEADER && decoded.wasm_size==0x010203,
          @"header decoder requires the exact frame length");
}

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
        if ([mode isEqual:@"invalid-utf8"] && i==0) {
            U32(imports,2); [imports appendData:BYTES(0xc0,0x80)];
        } else if ([mode isEqual:@"nul-import"] && i==0) {
            U32(imports,7); [imports appendData:Bytes((const uint8_t *)"alloc\0x",7)];
        } else Name(imports,[mode isEqual:@"unknown"] && i==0 ? @"config_get" : names[i]);
        AppendByte(imports,[mode isEqual:@"nonfunction"] && i==0 ? 1 : 0);
        U32(imports,[mode isEqual:@"wrong-import-type"] && i==0 ? 0 : (uint32_t)i+1);
    }
    Section(wasm,2,imports);
    BOOL start=[mode isEqual:@"start-loop"], isVoid=[mode isEqual:@"void"];
    Section(wasm,3,start ? BYTES(2,0,7) : isVoid ? BYTES(1,7) : BYTES(1,0));
    if ([mode isEqual:@"memory"]) Section(wasm,5,BYTES(1,0,0x81,0x08)); // minimum 1025 pages
    NSMutableData *exports=[NSMutableData data]; U32(exports,[mode isEqual:@"duplicate-export"] ? 2 : 1);
    if ([mode isEqual:@"nul-export"]) {
        U32(exports,10); [exports appendData:Bytes((const uint8_t *)"mooji_run\0x",10)];
    } else Name(exports,[mode isEqual:@"missing"] ? @"other" : @"mooji_run");
    AppendByte(exports,0); U32(exports,[mode isEqual:@"imported"] ? 0 : 6);
    if ([mode isEqual:@"duplicate-export"]) { Name(exports,@"mooji_run"); AppendByte(exports,0); U32(exports,6); }
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
    if ([mode isEqual:@"invalid-code"]) body=BYTES(0,0xff,0x0b);
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
static NSData *Packet(NSData *wasm, NSData *input) {
    NSMutableData *packet=[NSMutableData dataWithBytes:"MOOJIW1\0" length:8];
    uint32_t words[]={(uint32_t)wasm.length,(uint32_t)input.length,1000,1024,256*1024,0,50000000};
    for (NSUInteger i=0;i<sizeof(words)/sizeof(words[0]);i++) {
        uint32_t word=words[i];
        uint8_t bytes[]={(uint8_t)(word>>24),(uint8_t)(word>>16),(uint8_t)(word>>8),(uint8_t)word};
        [packet appendBytes:bytes length:sizeof(bytes)];
    }
    [packet appendData:wasm]; [packet appendData:input]; return packet;
}
// Exercise malformed framing directly: the normal parent intentionally refuses
// to send these requests. All packets/diagnostics here fit in one pipe buffer.
static void RejectPacket(NSURL *executable, NSData *packet, NSString *diagnostic) {
    NSTask *task=[NSTask new]; task.executableURL=executable;
    NSPipe *input=[NSPipe pipe], *output=[NSPipe pipe], *error=[NSPipe pipe];
    task.standardInput=input; task.standardOutput=output; task.standardError=error;
    NSError *failure=nil;
    Check([task launchAndReturnError:&failure],failure.localizedDescription ?: @"launch malformed IPC fixture");
    [input.fileHandleForWriting writeData:packet]; [input.fileHandleForWriting closeFile];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:5];
    while(task.running && deadline.timeIntervalSinceNow>0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    BOOL timedOut=task.running;
    if(timedOut) kill(task.processIdentifier,SIGKILL);
    [task waitUntilExit];
    NSData *bytes=[output.fileHandleForReading readDataToEndOfFile];
    NSString *message=[[NSString alloc] initWithData:[error.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding];
    Check(!timedOut && task.terminationStatus!=0 && !bytes.length && [message containsString:diagnostic],
          [NSString stringWithFormat:@"reject IPC %@: %@",diagnostic,message]);
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
        WireProtocol();
        NSURL *executable=[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
        NSData *input=[@"{\"apiVersion\":1,\"invocationId\":\"fixture\",\"toolId\":\"describe\",\"capture\":{\"width\":1440,\"height\":900,\"format\":\"png\",\"revision\":0}}" dataUsingEncoding:NSUTF8StringEncoding];
        MCPluginWorkerLimits limits=MCPluginWorkerDefaultLimits(); NSError *error=nil;
        NSData *output=Run(executable,Module(@"echo"),input,limits,-1,&error);
        Check(!error && [output isEqual:input],[NSString stringWithFormat:@"real Extism roundtrip: %@",error]);
        NSMutableData *binary=[NSMutableData dataWithLength:64*1024];
        for(NSUInteger i=0;i<binary.length;i++) ((uint8_t *)binary.mutableBytes)[i]=(uint8_t)i;
        output=Run(executable,Module(@"echo"),binary,limits,-1,&error);
        Check(!error && [output isEqual:binary],@"binary IPC preserves NUL, CR, LF, Ctrl+Z and high bytes at the input limit");
        NSData *packet=Packet(Module(@"echo"),input);
        RejectPacket(executable,[packet subdataWithRange:NSMakeRange(0,35)],@"header");
        RejectPacket(executable,[packet subdataWithRange:NSMakeRange(0,packet.length-1)],@"Truncated");
        NSMutableData *trailing=[packet mutableCopy]; AppendByte(trailing,0);
        RejectPacket(executable,trailing,@"trailing");
        NSMutableData *oversized=[[packet subdataWithRange:NSMakeRange(0,36)] mutableCopy];
        memset((uint8_t *)oversized.mutableBytes+8,0xff,4);
        RejectPacket(executable,oversized,@"limit exceeded");
        for (NSString *mode in @[@"void",@"missing",@"imported",@"wasi",@"unknown",@"nonfunction",@"section-order",
            @"invalid-utf8",@"nul-import",@"nul-export",@"duplicate-export",@"wrong-import-type"]) {
            Run(executable,Module(mode),input,limits,-1,&error);
            Check(error.code==MCPluginWorkerExecutionFailed && [error.localizedDescription containsString:@"Unsupported Wasm"],[NSString stringWithFormat:@"reject %@: %@",mode,error]);
        }
        NSMutableData *overflow=[NSMutableData dataWithBytes:"\0asm\1\0\0\0" length:8]; [overflow appendData:BYTES(1,0x80,0x80,0x80,0x80,0x10)];
        Run(executable,overflow,input,limits,-1,&error); Check(error.code==MCPluginWorkerExecutionFailed,@"reject LEB overflow");
        NSData *valid=Module(@"echo");
        Run(executable,Module(@"invalid-code"),input,limits,-1,&error);
        Check(error.code==MCPluginWorkerExecutionFailed && ![error.localizedDescription containsString:@"Unsupported Wasm"],
              @"runtime must validate instructions after the selected ABI check");
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
