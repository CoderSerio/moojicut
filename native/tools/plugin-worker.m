#import <Foundation/Foundation.h>
#include "extism.h"
#include <errno.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

// Private, one-request IPC: 8-byte magic, seven big-endian u32 words,
// then wasm bytes and input bytes. The last two words form the fuel u64.
static const uint32_t MaxWasm = 4*1024*1024, MaxInput = 64*1024, MaxOutput = 256*1024;
static BOOL ReadExact(void *bytes, size_t size) {
    size_t offset = 0;
    while (offset < size) {
        ssize_t n = read(STDIN_FILENO,(uint8_t *)bytes+offset,size-offset);
        if (n > 0) offset += (size_t)n;
        else if (n < 0 && errno == EINTR) continue;
        else return NO;
    }
    return YES;
}
static BOOL WriteExact(int fd, const void *bytes, size_t size) {
    size_t offset = 0;
    while (offset < size) {
        ssize_t n = write(fd,(const uint8_t *)bytes+offset,size-offset);
        if (n > 0) offset += (size_t)n;
        else if (n < 0 && errno == EINTR) continue;
        else return NO;
    }
    return YES;
}
static int Failure(const char *message) {
    if (!message) message = "Plugin execution failed";
    WriteExact(STDERR_FILENO,message,strnlen(message,4096));
    WriteExact(STDERR_FILENO,"\n",1); return 1;
}
static uint32_t BE32(const uint8_t *p) { return ((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[2]<<8)|p[3]; }
typedef struct { const uint8_t *bytes; size_t size, offset; BOOL failed; } Reader;
static uint8_t ReadByte(Reader *r) {
    if (r->offset >= r->size) { r->failed = YES; return 0; }
    return r->bytes[r->offset++];
}
static uint32_t U32(Reader *r) {
    uint32_t result = 0;
    for (unsigned i=0; i<5; i++) {
        uint8_t b = ReadByte(r);
        if (r->failed || (i==4 && (b&0xf0))) { r->failed = YES; return 0; }
        result |= (uint32_t)(b&0x7f)<<(i*7);
        if (!(b&0x80)) return result;
    }
    r->failed = YES; return 0;
}
static NSString *Name(Reader *r) {
    uint32_t length = U32(r);
    if (r->failed || length > 128 || length > r->size-r->offset) { r->failed = YES; return nil; }
    NSString *name = [[NSString alloc] initWithBytes:r->bytes+r->offset length:length encoding:NSUTF8StringEncoding];
    r->offset += length; if (!name) r->failed = YES; return name;
}
typedef struct { uint32_t params, results; uint8_t arguments[64], returns[16]; } FunctionType;
static BOOL ValueType(uint8_t b) { return b==0x7f || b==0x7e || b==0x7d || b==0x7c || b==0x7b || b==0x70 || b==0x6f; }
static BOOL ImportType(NSString *name, FunctionType type) {
    if ([name isEqual:@"output_set"]) return type.params==2 && type.arguments[0]==0x7e && type.arguments[1]==0x7e && type.results==0;
    if ([name isEqual:@"store_u8"]) return type.params==2 && type.arguments[0]==0x7e && type.arguments[1]==0x7f && type.results==0;
    if ([name isEqual:@"input_load_u8"]) return type.params==1 && type.arguments[0]==0x7e && type.results==1 && type.returns[0]==0x7f;
    if ([name isEqual:@"alloc"]) return type.params==1 && type.arguments[0]==0x7e && type.results==1 && type.returns[0]==0x7e;
    if ([name isEqual:@"input_length"]) return type.params==0 && type.results==1 && type.returns[0]==0x7e;
    if ([name isEqual:@"error_set"]) return type.params==1 && type.arguments[0]==0x7e && type.results==0;
    return NO;
}
// This bounded adapter checks the selected plain-wasm ABI, not all Wasm
// instructions. Wasmtime must still validate, instantiate and actually call it.
static BOOL ValidateModule(NSData *data) {
    if (data.length < 8 || memcmp(data.bytes,"\0asm\1\0\0\0",8)) return NO;
    Reader module = {(const uint8_t *)data.bytes+8,data.length-8,0,NO};
    FunctionType *types = calloc(4096,sizeof(FunctionType));
    uint32_t *functions = calloc(65536,sizeof(uint32_t));
    if (!types || !functions) { free(types); free(functions); return NO; }
    uint32_t typeCount=0, functionCount=0, importCount=0, entry=UINT32_MAX;
    uint16_t seen=0; uint8_t lastRank=0; BOOL valid=YES;
    while (valid && module.offset < module.size) {
        uint8_t id = ReadByte(&module); uint32_t length = U32(&module);
        if (module.failed || id>12 || length>module.size-module.offset || (id && (seen&(1u<<id)))) { valid=NO; break; }
        uint8_t rank = id==12 ? 10 : id>=10 ? id+1 : id;
        if (id && rank<=lastRank) { valid=NO; break; }
        if (id) { seen |= 1u<<id; lastRank=rank; }
        Reader section = {module.bytes+module.offset,length,0,NO}; module.offset += length;
        if (id==1) {
            typeCount=U32(&section);
            if (typeCount>4096) { valid=NO; break; }
            for (uint32_t i=0; i<typeCount && !section.failed; i++) {
                if (ReadByte(&section)!=0x60) { section.failed=YES; break; }
                types[i].params=U32(&section);
                if (types[i].params>64) { section.failed=YES; break; }
                for (uint32_t j=0;j<types[i].params;j++) if (!ValueType(types[i].arguments[j]=ReadByte(&section))) section.failed=YES;
                types[i].results=U32(&section);
                if (types[i].results>16) { section.failed=YES; break; }
                for (uint32_t j=0;j<types[i].results;j++) if (!ValueType(types[i].returns[j]=ReadByte(&section))) section.failed=YES;
            }
        } else if (id==2) {
            uint32_t count=U32(&section);
            if (count>64 || count>65536-functionCount) { valid=NO; break; }
            for (uint32_t i=0;i<count && !section.failed;i++) {
                NSString *space=Name(&section), *name=Name(&section); uint8_t kind=ReadByte(&section);
                if (section.failed || kind!=0 || ![space isEqual:@"extism:host/env"]) { section.failed=YES; break; }
                uint32_t type=U32(&section);
                if (section.failed || type>=typeCount || !ImportType(name,types[type])) { section.failed=YES; break; }
                functions[functionCount++]=type; importCount++;
            }
        } else if (id==3) {
            uint32_t count=U32(&section);
            if (count>65536-functionCount) { valid=NO; break; }
            for (uint32_t i=0;i<count && !section.failed;i++) {
                uint32_t type=U32(&section);
                if (type>=typeCount) { section.failed=YES; break; }
                functions[functionCount++]=type;
            }
        } else if (id==7) {
            uint32_t count=U32(&section);
            if (count>256) { valid=NO; break; }
            NSMutableSet *names=[NSMutableSet set];
            for (uint32_t i=0;i<count && !section.failed;i++) {
                NSString *name=Name(&section); uint8_t kind=ReadByte(&section); uint32_t index=U32(&section);
                if (section.failed || [names containsObject:name]) { section.failed=YES; break; }
                [names addObject:name];
                if ([name isEqual:@"mooji_run"]) {
                    if (kind!=0 || index<importCount || index>=functionCount) { section.failed=YES; break; }
                    entry=index;
                }
            }
        } else section.offset=section.size;
        if (section.failed || section.offset!=section.size) valid=NO;
    }
    if (entry==UINT32_MAX || entry>=functionCount) valid=NO;
    if (valid) { FunctionType t=types[functions[entry]]; valid=t.params==0 && t.results==1 && t.returns[0]==0x7f; }
    free(types); free(functions); return valid;
}
int main(void) {
    @autoreleasepool {
        uint8_t header[36];
        if (!ReadExact(header,sizeof(header)) || memcmp(header,"MOOJIW1\0",8)) return Failure("Invalid worker IPC header");
        uint32_t wasmSize=BE32(header+8), inputSize=BE32(header+12), timeout=BE32(header+16), pages=BE32(header+20), outputLimit=BE32(header+24);
        uint64_t fuel=((uint64_t)BE32(header+28)<<32)|BE32(header+32);
        if (!wasmSize || wasmSize>MaxWasm || !inputSize || inputSize>MaxInput || !timeout || timeout>1000 ||
            !pages || pages>1024 || !outputLimit || outputLimit>MaxOutput || !fuel || fuel>50000000)
            return Failure("Worker IPC limit exceeded");
        NSMutableData *wasm=[NSMutableData dataWithLength:wasmSize], *input=[NSMutableData dataWithLength:inputSize];
        if (!ReadExact(wasm.mutableBytes,wasmSize) || !ReadExact(input.mutableBytes,inputSize)) return Failure("Truncated worker request");
        uint8_t extra; ssize_t remaining;
        do { remaining=read(STDIN_FILENO,&extra,1); } while (remaining<0 && errno==EINTR);
        if (remaining!=0) return Failure("Unexpected trailing worker input");
        if (!ValidateModule(wasm)) return Failure("Unsupported Wasm imports, sections or mooji_run signature");
        if (strcmp(extism_version(),"1.41.0")) return Failure("Unexpected Extism runtime version");
        NSDictionary *manifest=@{@"wasm":@[@{@"data":[wasm base64EncodedStringWithOptions:0]}],
            @"timeout_ms":@(timeout), @"memory":@{@"max_pages":@(pages), @"max_http_response_bytes":@0, @"max_var_bytes":@0},
            @"allowed_hosts":@[], @"allowed_paths":@{}};
        NSData *encoded=[NSJSONSerialization dataWithJSONObject:manifest options:0 error:NULL];
        char *error=NULL;
        ExtismPlugin *plugin=extism_plugin_new_with_fuel_limit(encoded.bytes,encoded.length,NULL,0,false,fuel,&error);
        if (!plugin) { int result=Failure(error); if (error) extism_plugin_new_error_free(error); return result; }
        if (!extism_plugin_function_exists(plugin,"mooji_run")) { extism_plugin_free(plugin); return Failure("Missing mooji_run export"); }
        int32_t status=extism_plugin_call(plugin,"mooji_run",input.bytes,input.length);
        if (status!=EXTISM_SUCCESS) { int result=Failure(extism_plugin_error(plugin)); extism_plugin_free(plugin); return result; }
        ExtismSize length=extism_plugin_output_length(plugin);
        if (length>outputLimit) { extism_plugin_free(plugin); return Failure("Plugin output limit exceeded"); }
        const uint8_t *output=extism_plugin_output_data(plugin);
        if (length && !output) { extism_plugin_free(plugin); return Failure("Missing plugin output bytes"); }
        NSData *result=[NSData dataWithBytes:output length:(NSUInteger)length];
        extism_plugin_free(plugin);
        return WriteExact(STDOUT_FILENO,result.bytes,result.length) ? 0 : Failure("Cannot write plugin output");
    }
}
