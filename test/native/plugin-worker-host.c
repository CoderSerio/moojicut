/* Real packaged MoonBit/Extism integration plus bounded, benign pipe fixtures.
 * The successful plugin requests always use the unchanged Wasm extracted from
 * the example ZIP. Child modes exercise OS transport only; none impersonates
 * the plugin runtime or returns a fabricated plugin JSON result. */
#ifndef _WIN32
#define _POSIX_C_SOURCE 200809L
#endif
#include "platform/shared/plugin_host/worker_process.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <fcntl.h>
#include <io.h>
#include <wchar.h>
#else
#include <signal.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#endif

static unsigned checks;
static void check(int condition, const char *description) {
    checks++;
    if (!condition) { fprintf(stderr,"FAIL plugin worker host: %s\n",description); exit(1); }
}
static uint64_t now_ms(void) {
#ifdef _WIN32
    return (uint64_t)GetTickCount64();
#else
    struct timespec time;
    if (clock_gettime(CLOCK_MONOTONIC,&time)) abort();
    return (uint64_t)time.tv_sec*1000u+(uint64_t)time.tv_nsec/1000000u;
#endif
}
static void pause_ms(unsigned ms) {
#ifdef _WIN32
    Sleep(ms);
#else
    struct timespec delay={(time_t)(ms/1000u),(long)(ms%1000u)*1000000L};
    while (nanosleep(&delay,&delay) && errno==EINTR) {}
#endif
}
static uint32_t process_id(void) {
#ifdef _WIN32
    return (uint32_t)GetCurrentProcessId();
#else
    return (uint32_t)getpid();
#endif
}
#ifdef _WIN32
static wchar_t *wide_path(const char *path) {
    int count=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,path,-1,NULL,0);
    if (!count) return NULL;
    wchar_t *value=malloc((size_t)count*sizeof(*value));
    if (!value) return NULL;
    if (MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,path,-1,value,count)!=count) { free(value); return NULL; }
    return value;
}
static char *utf8_path(const wchar_t *path) {
    int count=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,path,-1,NULL,0,NULL,NULL);
    if (!count) return NULL;
    char *value=malloc((size_t)count);
    if (!value) return NULL;
    if (WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,path,-1,value,count,NULL,NULL)!=count) { free(value); return NULL; }
    return value;
}
#endif
static FILE *open_file(const char *path, int write) {
#ifdef _WIN32
    wchar_t *wide=wide_path(path);
    if (!wide) return NULL;
    FILE *file=NULL;
#if defined(_MSC_VER)
    if (_wfopen_s(&file,wide,write ? L"wb" : L"rb")) file=NULL;
#else
    file=_wfopen(wide,write ? L"wb" : L"rb");
#endif
    free(wide);
    return file;
#else
    return fopen(path,write ? "wb" : "rb");
#endif
}
static char *join_path(const char *directory, const char *name) {
    size_t left=strlen(directory), right=strlen(name);
    check(left<=65536 && right<=256,"bounded fixture path");
    char *path=malloc(left+right+2);
    check(path!=NULL,"allocate fixture path");
    memcpy(path,directory,left); path[left]='/'; memcpy(path+left+1,name,right+1);
    return path;
}
static int make_directory(const char *path) {
#ifdef _WIN32
    wchar_t *wide=wide_path(path);
    int result=wide && CreateDirectoryW(wide,NULL)!=0;
    free(wide); return result;
#else
    return mkdir(path,0700)==0;
#endif
}
static int delete_path(const char *path, int directory) {
#ifdef _WIN32
    wchar_t *wide=wide_path(path);
    int result=wide && (directory ? RemoveDirectoryW(wide) : DeleteFileW(wide));
    free(wide); return result;
#else
    return (directory ? rmdir(path) : unlink(path))==0;
#endif
}
static void write_file(const char *path, const uint8_t *bytes, size_t size) {
    FILE *file=open_file(path,1);
    check(file!=NULL,"open result artifact");
    check(fwrite(bytes,1,size,file)==size,"write complete result artifact");
    check(fclose(file)==0,"close result artifact");
}
static uint8_t *read_wasm(const char *path, size_t *size) {
    FILE *file=open_file(path,0);
    check(file!=NULL,"open actual packaged MoonBit Wasm");
    uint8_t *bytes=malloc(MC_WASM_MAX_MODULE_BYTES+1u);
    check(bytes!=NULL,"allocate bounded sample bytes");
    size_t length=fread(bytes,1,MC_WASM_MAX_MODULE_BYTES+1u,file);
    check(!ferror(file) && length>=8 && length<=MC_WASM_MAX_MODULE_BYTES && feof(file),"sample has bounded complete contents");
    check(fclose(file)==0 && !memcmp(bytes,"\0asm\1\0\0\0",8),"sample is a real core Wasm module");
    *size=length; return bytes;
}
static void copy_executable(const char *source, const char *target) {
    FILE *input=open_file(source,0), *output=open_file(target,1);
    check(input && output,"copy benign child executable");
    uint8_t buffer[16384]; size_t count;
    while ((count=fread(buffer,1,sizeof(buffer),input))!=0)
        check(fwrite(buffer,1,count,output)==count,"copy complete child bytes");
    check(!ferror(input),"read complete fixture executable");
    check(fclose(input)==0 && fclose(output)==0,"close fixture executable files");
#ifndef _WIN32
    check(chmod(target,0700)==0,"make private child executable");
#endif
}
static int contains(const uint8_t *bytes, size_t size, const char *text) {
    size_t length=strlen(text);
    if (length>size) return 0;
    for (size_t i=0;i<=size-length;i++) if (!memcmp(bytes+i,text,length)) return 1;
    return 0;
}
static int io_write(int fd, const uint8_t *bytes, size_t size) {
    while (size) {
        size_t chunk=size<4096 ? size : 4096;
#ifdef _WIN32
        int count=_write(fd,bytes,(unsigned)chunk);
#else
        ssize_t count=write(fd,bytes,chunk);
#endif
        if (count<0 && errno==EINTR) continue;
        if (count<=0) return 0;
        bytes+=(size_t)count; size-=(size_t)count;
    }
    return 1;
}
static long io_read(uint8_t *bytes, size_t size) {
#ifdef _WIN32
    return (long)_read(0,bytes,(unsigned)size);
#else
    return (long)read(0,bytes,size);
#endif
}
static int child_mode(const char *name) {
    if (strncmp(name,"mc-plugin-child-",16)) return -1;
#ifdef _WIN32
    if (_setmode(0,_O_BINARY)<0 || _setmode(1,_O_BINARY)<0 || _setmode(2,_O_BINARY)<0) return 70;
#else
    signal(SIGTERM,SIG_IGN);
    signal(SIGPIPE,SIG_IGN);
#endif
    char marker[96];
    int length=snprintf(marker,sizeof(marker),"PID=%" PRIu32 "\n",process_id());
    if (length<0 || (size_t)length>=sizeof(marker) || !io_write(2,(const uint8_t *)marker,(size_t)length)) return 71;
    if (strstr(name,"stall")) {
        // Deliberately never reads stdin; finite lifetime even if a broken
        // parent/harness disappears. SIGTERM is ignored to exercise escalation.
        pause_ms(10000); return 72;
    }
    if (strstr(name,"exit")) return 17;
    uint8_t buffer[4096];
    if (strstr(name,"stdout") || strstr(name,"stderr")) {
        memset(buffer,'x',1024);
        return io_write(strstr(name,"stderr") ? 2 : 1,buffer,1024) ? 0 : 73;
    }
    if (!strstr(name,"drain")) return 74;
    size_t total=0;
    for (;;) {
        long count=io_read(buffer,sizeof(buffer));
        if (count<0 && errno==EINTR) continue;
        if (count<0 || total>MC_WASM_MAX_MODULE_BYTES+MC_WASM_MAX_INPUT_BYTES+MC_PLUGIN_WIRE_HEADER_BYTES) return 75;
        if (!count) break;
        total+=(size_t)count;
    }
    length=snprintf(marker,sizeof(marker),"INPUT=%zu\n",total);
    if (length<0 || (size_t)length>=sizeof(marker) || !io_write(2,(const uint8_t *)marker,(size_t)length)) return 76;
    // More than a pipe buffer, including NUL/CR/LF/Ctrl-Z and high bytes. An
    // early 'process exited' completion cannot pass the final-byte assertions.
    for (size_t base=0;base<131071u;base+=sizeof(buffer)) {
        size_t count=131071u-base; if (count>sizeof(buffer)) count=sizeof(buffer);
        for (size_t i=0;i<count;i++) buffer[i]=(uint8_t)((base+i)%251u);
        if (!io_write(1,buffer,count)) return 77;
    }
    memset(buffer,'d',sizeof(buffer));
    return io_write(2,buffer,sizeof(buffer)) ? 0 : 78;
}

static void assert_reaped(const MCPluginProcessResult *result, int required) {
    char marker[64]; size_t count=result->diagnostics_size;
    if (count>=sizeof(marker)) count=sizeof(marker)-1;
    if (count) memcpy(marker,result->diagnostics,count);
    marker[count]=0;
    char *end=NULL;
    unsigned long id=strncmp(marker,"PID=",4) ? 0 : strtoul(marker+4,&end,10);
    if (!id) { check(!required,"terminal child reported its process identity"); return; }
    check(end && *end=='\n' && id<=UINT32_MAX,"bounded child PID marker");
#ifdef _WIN32
    HANDLE process=OpenProcess(SYNCHRONIZE,FALSE,(DWORD)id);
    if (process) {
        check(WaitForSingleObject(process,0)==WAIT_OBJECT_0,"terminal result follows actual process exit");
        CloseHandle(process);
    } else check(GetLastError()==ERROR_INVALID_PARAMETER,"terminal process has been released");
#else
    errno=0;
    check(kill((pid_t)id,0)==-1 && errno==ESRCH,"terminal result follows process reaping, not just exit notification");
#endif
}
static MCPluginProcessStatus await_process(MCPluginProcess *process, MCPluginProcessResult *result, int cancel_after_ms) {
    check(process!=NULL,"asynchronous process request accepted");
    uint64_t start=now_ms();
    int cancelled=0;
    MCPluginProcessStatus status;
    do {
        memset(result,0x55,sizeof(*result));
        status=mc_plugin_process_poll(process,result);
        if (status!=MC_PLUGIN_PROCESS_RUNNING) break;
        check(!result->output && !result->diagnostics && !result->output_size && !result->diagnostics_size &&
              !result->exit_code && !result->system_error,"running poll exposes no mutable borrowed result");
        check(mc_plugin_process_close(process)==0,"running close cannot release live process resources");
        uint64_t elapsed=now_ms()-start;
        if (!cancelled && cancel_after_ms>=0 && elapsed>=(uint64_t)cancel_after_ms) {
            mc_plugin_process_cancel(process); cancelled=1;
        }
        if (elapsed>8000) { mc_plugin_process_cancel(process); check(0,"process failed to reach reaped terminal state within fixture deadline"); }
        pause_ms(2);
    } while (1);
    MCPluginProcessResult terminal=*result, again;
    mc_plugin_process_cancel(process);
    pause_ms(5);
    check(mc_plugin_process_poll(process,&again)==status && again.output==terminal.output &&
          again.diagnostics==terminal.diagnostics && again.output_size==terminal.output_size &&
          again.diagnostics_size==terminal.diagnostics_size && again.exit_code==terminal.exit_code &&
          again.system_error==terminal.system_error,"late cancellation and repeated polling preserve the immutable terminal result");
    return status;
}
static MCPluginProcessRequest request_for(const char *worker, const uint8_t *wasm, size_t wasm_size, const char *input) {
    MCPluginProcessRequest request={0};
    request.executable=worker; request.wasm=wasm; request.input=(const uint8_t *)input;
    request.wire.wasm_size=wasm_size; request.wire.input_size=strlen(input);
    request.wire.max_output_bytes=MC_WASM_MAX_OUTPUT_BYTES; request.wire.fuel=MC_WASM_MAX_FUEL;
    request.wire.timeout_ms=MC_WASM_MAX_TIMEOUT_MS; request.wire.max_memory_pages=MC_WASM_MAX_MEMORY_PAGES;
    request.max_stderr_bytes=MC_PLUGIN_MAX_STDERR_BYTES; request.wall_ms=5000;
    return request;
}
static void sample_request(const char *worker, const uint8_t *wasm, size_t size, const char *scratch, int describe) {
    const char *input=describe
        ? "{\"apiVersion\":1,\"invocationId\":\"host-description-42\",\"toolId\":\"describe\",\"capture\":{\"width\":320,\"height\":180,\"format\":\"png\",\"revision\":7}}"
        : "{\"apiVersion\":1,\"invocationId\":\"host-dimensions-43\",\"toolId\":\"copy-size\",\"capture\":{\"width\":320,\"height\":180,\"format\":\"png\",\"revision\":7}}";
    MCPluginProcessRequest request=request_for(worker,wasm,size,input);
    MCPluginProcess *process=mc_plugin_process_start(&request);
    MCPluginProcessResult result;
    MCPluginProcessStatus status=await_process(process,&result,-1);
    if (status!=MC_PLUGIN_PROCESS_OK) fprintf(stderr,"sample status=%d exit=%" PRIu32 " os=%" PRIu32 " diagnostic=%.*s\n",
        (int)status,result.exit_code,result.system_error,(int)result.diagnostics_size,result.diagnostics ? (const char *)result.diagnostics : "");
    check(status==MC_PLUGIN_PROCESS_OK && result.exit_code==0 && result.output_size>0,"actual packaged MoonBit sample runs through the real child/Extism runtime");
    check(contains(result.output,result.output_size,"\"apiVersion\":1") && contains(result.output,result.output_size,"\"kind\":\"text\"") &&
          contains(result.output,result.output_size,describe ? "\"invocationId\":\"host-description-42\"" : "\"invocationId\":\"host-dimensions-43\""),
          "actual response preserves protocol and invocation identity");
    check(contains(result.output,result.output_size,describe ? "截图信息" : "查看尺寸") &&
          contains(result.output,result.output_size,"320 × 180") &&
          (!describe || contains(result.output,result.output_size,"元数据")),"UTF-8 Chinese labels and multiplication sign survive binary worker IPC");
    char *path=join_path(scratch,describe ? "describe-result.json" : "copy-size-result.json");
    write_file(path,result.output,result.output_size); free(path);
    check(mc_plugin_process_close(process)==1,"dispose completed actual plugin invocation");
}
static int run_fixture(int argc, char **argv) {
    const char *name=argv[0];
    for (const char *p=argv[0];*p;p++) if (*p=='/' || *p=='\\') name=p+1;
    int child=child_mode(name);
    if (child>=0) return child;
    check(argc==4,"usage: plugin-worker-host WORKER_EXE EXTRACTED_PLUGIN_WASM SCRATCH_DIR (absolute UTF-8 paths)");
    size_t wasm_size=0; uint8_t *wasm=read_wasm(argv[2],&wasm_size);
    sample_request(argv[1],wasm,wasm_size,argv[3],1);
    char directory_name[96];
    int length=snprintf(directory_name,sizeof(directory_name),"worker fixtures with spaces-%" PRIu32,process_id());
    check(length>0 && (size_t)length<sizeof(directory_name),"format private fixture directory");
    char *directory=join_path(argv[3],directory_name);
    check(make_directory(directory),"create fresh private child directory containing spaces");
    const char *modes[]={"stall","drain","exit","stdout","stderr"};
    char *children[5]={0};
    for (size_t i=0;i<5;i++) {
        char file[96];
        length=snprintf(file,sizeof(file),"mc-plugin-child-%s%s",modes[i],
#ifdef _WIN32
            ".exe"
#else
            ""
#endif
        );
        check(length>0 && (size_t)length<sizeof(file),"format child fixture filename");
        children[i]=join_path(directory,file); copy_executable(argv[0],children[i]);
    }
    const char *json="{\"apiVersion\":1,\"invocationId\":\"host-description-42\",\"toolId\":\"describe\",\"capture\":{\"width\":320,\"height\":180,\"format\":\"png\",\"revision\":7}}";
    MCPluginProcessRequest request=request_for(children[1],wasm,wasm_size,json);
    MCPluginProcessResult result;
    MCPluginProcess *process=mc_plugin_process_start(&request);
    MCPluginProcessStatus status=await_process(process,&result,-1);
    check(status==MC_PLUGIN_PROCESS_OK && result.output_size==131071u,"all buffered stdout is drained before successful terminal publication");
    for (size_t i=0;i<result.output_size;i++) if (result.output[i]!=(uint8_t)(i%251u)) check(0,"binary output is unchanged through CR/LF, Ctrl-Z and high bytes");
    char input_marker[64];
    length=snprintf(input_marker,sizeof(input_marker),"INPUT=%zu\n",MC_PLUGIN_WIRE_HEADER_BYTES+wasm_size+strlen(json));
    check(length>0 && (size_t)length<sizeof(input_marker) && contains(result.diagnostics,result.diagnostics_size,input_marker) &&
          result.diagnostics_size>=4096 && result.diagnostics[result.diagnostics_size-1]=='d',"stdin reaches exact EOF and stderr tail is fully drained");
    assert_reaped(&result,1); check(mc_plugin_process_close(process)==1,"close fully drained pipe fixture");
    // Large inert transport bytes are sent only to non-reading benign children,
    // never to the plugin runtime. They guarantee that stdin cannot fit in a pipe.
    uint8_t *large=calloc(1,MC_WASM_MAX_MODULE_BYTES);
    check(large!=NULL,"allocate bounded blocked-stdin payload");
    request=request_for(children[0],large,MC_WASM_MAX_MODULE_BYTES,json); request.wall_ms=500;
    uint64_t started=now_ms(); process=mc_plugin_process_start(&request);
    status=await_process(process,&result,-1);
    check(status==MC_PLUGIN_PROCESS_TIMED_OUT && now_ms()-started<3000,"wall deadline covers startup and blocked stdin, including termination escalation");
    assert_reaped(&result,0); check(!result.output && !result.output_size && mc_plugin_process_close(process)==1,"deadline publishes no success payload and releases the child");
    request.wall_ms=5000; started=now_ms(); process=mc_plugin_process_start(&request);
    status=await_process(process,&result,100);
    check(status==MC_PLUGIN_PROCESS_CANCELLED && now_ms()-started<3000,"cancellation drains and reaps a child which never consumes its input");
    assert_reaped(&result,0); check(mc_plugin_process_close(process)==1,"dispose cancelled child after terminal state");
    request.executable=children[2]; process=mc_plugin_process_start(&request);
    status=await_process(process,&result,-1);
    check(status==MC_PLUGIN_PROCESS_EXECUTION_FAILED || status==MC_PLUGIN_PROCESS_IO_FAILED,"early child exit reports failure without terminating the parent on a broken input pipe");
    assert_reaped(&result,0); check(mc_plugin_process_close(process)==1,"dispose early-exit child");
    free(large);
    for (size_t i=3;i<5;i++) {
        request=request_for(children[i],wasm,wasm_size,json);
        request.wire.max_output_bytes=64; request.max_stderr_bytes=64;
        process=mc_plugin_process_start(&request); status=await_process(process,&result,-1);
        check(status==MC_PLUGIN_PROCESS_LIMIT_EXCEEDED && !result.output && !result.output_size,"bounded benign stdout/stderr bursts enforce independent parent output caps");
        assert_reaped(&result,0); check(mc_plugin_process_close(process)==1,"dispose capped-output child");
    }
    char *missing=join_path(directory,"absent trusted helper.exe");
    request=request_for(missing,wasm,wasm_size,json); process=mc_plugin_process_start(&request);
    status=await_process(process,&result,-1);
    check(status==MC_PLUGIN_PROCESS_LAUNCH_FAILED && mc_plugin_process_close(process)==1,"nonexistent trusted helper terminates with a launch error");
    free(missing);
    request=request_for(argv[1],wasm,wasm_size,json); request.wire.input_size=0;
    check(mc_plugin_process_start(&request)==NULL,"invalid request is rejected before creating a process");
    sample_request(argv[1],wasm,wasm_size,argv[3],0);
    size_t final_size=0; uint8_t *final=read_wasm(argv[2],&final_size);
    check(final_size==wasm_size && !memcmp(final,wasm,wasm_size),"packaged source Wasm remains byte-identical after all invocations and cancellations");
    free(final); free(wasm);
    for (size_t i=0;i<5;i++) { check(delete_path(children[i],0),"release executable files after actual child reaping"); free(children[i]); }
    check(delete_path(directory,1),"remove only the fixture-owned private directory"); free(directory);
    printf("PASS cross-platform plugin worker host: %u checks; packaged MoonBit Unicode, binary pipes, limits, cancellation, deadlines and reaping.\n",checks);
    return 0;
}
#ifdef _WIN32
int wmain(int argc, wchar_t **wide_argv) {
    char **argv=calloc((size_t)argc+1,sizeof(*argv));
    if (!argv) return 1;
    for (int i=0;i<argc;i++) { argv[i]=utf8_path(wide_argv[i]); if (!argv[i]) abort(); }
    int result=run_fixture(argc,argv);
    for (int i=0;i<argc;i++) free(argv[i]);
    free(argv); return result;
}
#else
int main(int argc, char **argv) { return run_fixture(argc,argv); }
#endif
