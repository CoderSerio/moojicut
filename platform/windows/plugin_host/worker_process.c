/* The supported desktop baseline includes atomic Job assignment at launch. */
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include "../../shared/plugin_host/worker_process_internal.h"
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

/* Only the controller touches child handles. The application thread performs
 * zero-time thread queries and signals cancellation; it never waits on pipe IO.
 * The controller is the sole reader of each synchronous pipe. A separate writer
 * lets it enforce the deadline even when the child does not consume stdin. */
struct MCPluginProcess {
    HANDLE controller, cancelled;
    wchar_t *executable, *directory, *command_line;
    uint8_t *payload, *output, *diagnostics;
    size_t payload_size, output_capacity, diagnostic_capacity;
    ULONGLONG started;
    DWORD wall_ms;
    MCPluginProcessStatus status;
    MCPluginProcessResult result;
};

typedef struct {
    HANDLE pipe, cancelled;
    const uint8_t *bytes;
    size_t size;
    DWORD error;
} InputWriter;

static void close_handle(HANDLE *handle) {
    if (*handle && *handle != INVALID_HANDLE_VALUE) CloseHandle(*handle);
    *handle = NULL;
}

static int separator(wchar_t c) { return c == L'\\' || c == L'/'; }

static int drive_absolute(const wchar_t *path) {
    return ((path[0] >= L'A' && path[0] <= L'Z') ||
            (path[0] >= L'a' && path[0] <= L'z')) &&
        path[1] == L':' && separator(path[2]);
}

static int unc_absolute(const wchar_t *path) {
    /* Require both server and share, and an executable below the share. */
    const wchar_t *server = path;
    while (*path && !separator(*path)) ++path;
    if (path == server || !*path) return 0;
    const wchar_t *share = ++path;
    while (*path && !separator(*path)) ++path;
    return path != share && *path && path[1];
}

static int copy_executable(MCPluginProcess *process, const char *path) {
    if (!path) return 0;
    size_t size = 0;
    while (size < 4u * 32767u && path[size]) ++size;
    if (!size || size == 4u * 32767u) return 0;
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path,
                                  (int)size, NULL, 0);
    if (count < 4 || count > 32760) return 0;
    size_t length = (size_t)count;
    process->executable = calloc(length + 1u, sizeof(wchar_t));
    process->directory = calloc(length + 1u, sizeof(wchar_t));
    process->command_line = calloc(length + 3u, sizeof(wchar_t));
    if (!process->executable || !process->directory || !process->command_line ||
        MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, (int)size,
                           process->executable, count) != count) return 0;
    const wchar_t *wide = process->executable;
    int absolute = drive_absolute(wide);
    if (separator(wide[0]) && separator(wide[1])) {
        if (wide[2] == L'?' && separator(wide[3])) {
            absolute = length >= 7u && drive_absolute(wide + 4);
            if (length >= 9u && _wcsnicmp(wide + 4, L"UNC\\", 4) == 0)
                absolute = unc_absolute(wide + 8);
        } else if (wide[2] != L'.') {
            absolute = unc_absolute(wide + 2);
        }
    }
    if (!absolute || separator(wide[length - 1u])) return 0;
    size_t last_separator = 0;
    for (size_t i = 0; i < length; ++i) {
        if (wide[i] < 32 || wide[i] == L'"') return 0;
        if (separator(wide[i])) last_separator = i;
    }
    /* Keep the slash on a drive root, including an extended-length root. */
    size_t parent_size = last_separator;
    if (last_separator && wide[last_separator - 1u] == L':') ++parent_size;
    memcpy(process->directory, wide, parent_size * sizeof(wchar_t));
    process->command_line[0] = L'"';
    memcpy(process->command_line + 1, wide, length * sizeof(wchar_t));
    process->command_line[length + 1u] = L'"';
    return 1;
}

static int append_environment(wchar_t *buffer, size_t capacity, size_t *used,
                              const wchar_t *name, const wchar_t *value) {
    size_t a = wcslen(name), b = wcslen(value);
    if (*used + a + b + 2u >= capacity) return 0;
    memcpy(buffer + *used, name, a * sizeof(wchar_t));
    *used += a;
    buffer[(*used)++] = L'=';
    memcpy(buffer + *used, value, b * sizeof(wchar_t));
    *used += b;
    buffer[(*used)++] = 0;
    buffer[*used] = 0;
    return 1;
}

static int child_environment(wchar_t *buffer, size_t capacity) {
    wchar_t windows[MAX_PATH + 1], system[MAX_PATH + 1];
    UINT a = GetWindowsDirectoryW(windows, MAX_PATH + 1);
    UINT b = GetSystemDirectoryW(system, MAX_PATH + 1);
    if (!a || !b) return 0;
    if (a > MAX_PATH || b > MAX_PATH) {
        SetLastError(ERROR_FILENAME_EXCED_RANGE);
        return 0;
    }
    size_t used = 0;
    if (!append_environment(buffer, capacity, &used, L"PATH", system) ||
        !append_environment(buffer, capacity, &used, L"SystemRoot", windows) ||
        !append_environment(buffer, capacity, &used, L"WINDIR", windows)) {
        SetLastError(ERROR_INSUFFICIENT_BUFFER);
        return 0;
    }
    return 1;
}

static int pipe_pair(HANDLE *read_end, HANDLE *write_end, HANDLE *parent_end) {
    SECURITY_ATTRIBUTES security = { sizeof(security), NULL, TRUE };
    if (!CreatePipe(read_end, write_end, &security, 0)) return 0;
    return SetHandleInformation(*parent_end, HANDLE_FLAG_INHERIT, 0) != 0;
}

static DWORD WINAPI write_input(void *context) {
    InputWriter *writer = context;
    size_t offset = 0;
    while (offset < writer->size) {
        if (WaitForSingleObject(writer->cancelled, 0) == WAIT_OBJECT_0) {
            writer->error = ERROR_OPERATION_ABORTED;
            break;
        }
        size_t remaining = writer->size - offset;
        DWORD count = (DWORD)(remaining > 65536u ? 65536u : remaining), written = 0;
        if (!WriteFile(writer->pipe, writer->bytes + offset, count, &written, NULL)) {
            writer->error = GetLastError();
            break;
        }
        if (!written) {
            writer->error = ERROR_WRITE_FAULT;
            break;
        }
        offset += written;
    }
    close_handle(&writer->pipe); /* The protocol requires EOF after the payload. */
    return 0;
}

static MCPluginProcessStatus interruption(const MCPluginProcess *process) {
    if (WaitForSingleObject(process->cancelled, 0) == WAIT_OBJECT_0)
        return MC_PLUGIN_PROCESS_CANCELLED;
    if (GetTickCount64() - process->started >= process->wall_ms)
        return MC_PLUGIN_PROCESS_TIMED_OUT;
    return MC_PLUGIN_PROCESS_RUNNING;
}

static void fail_once(MCPluginProcessStatus *status, DWORD *system_error,
                      MCPluginProcessStatus failure, DWORD error) {
    if (*status == MC_PLUGIN_PROCESS_RUNNING) {
        *status = failure;
        *system_error = error;
    }
}

/* Read at most one bounded chunk before rechecking cancellation/deadline. No
 * other thread reads this pipe, so bytes reported by Peek cannot be consumed
 * between Peek and ReadFile. Keep draining after overflow, without allocating. */
static void drain_pipe(HANDLE *pipe, uint8_t *bytes, size_t capacity, size_t *size,
                       MCPluginProcessStatus *status, DWORD *system_error) {
    if (!*pipe) return;
    DWORD available = 0;
    if (!PeekNamedPipe(*pipe, NULL, 0, NULL, &available, NULL)) {
        DWORD error = GetLastError();
        if (error != ERROR_BROKEN_PIPE)
            fail_once(status, system_error, MC_PLUGIN_PROCESS_IO_FAILED, error);
        close_handle(pipe);
        return;
    }
    if (!available) return;
    uint8_t scratch[8192];
    DWORD requested = available > sizeof(scratch) ? (DWORD)sizeof(scratch) : available;
    DWORD received = 0;
    if (!ReadFile(*pipe, scratch, requested, &received, NULL)) {
        DWORD error = GetLastError();
        if (error != ERROR_BROKEN_PIPE)
            fail_once(status, system_error, MC_PLUGIN_PROCESS_IO_FAILED, error);
        close_handle(pipe);
        return;
    }
    size_t remaining = capacity - *size;
    size_t keep = received > remaining ? remaining : (size_t)received;
    if (keep) memcpy(bytes + *size, scratch, keep);
    *size += keep;
    if (received > remaining)
        fail_once(status, system_error, MC_PLUGIN_PROCESS_LIMIT_EXCEEDED, ERROR_BUFFER_OVERFLOW);
}

static DWORD WINAPI control_process(void *context) {
    MCPluginProcess *process = context;
    HANDLE input_read = NULL, input_write = NULL, output_read = NULL, output_write = NULL;
    HANDLE error_read = NULL, error_write = NULL, job = NULL, writer_thread = NULL;
    PROCESS_INFORMATION child = {0};
    STARTUPINFOEXW startup = {0};
    LPPROC_THREAD_ATTRIBUTE_LIST attributes = NULL;
    int attributes_initialized = 0, terminating = 0;
    InputWriter writer = {0};
    MCPluginProcessStatus status = interruption(process);
    DWORD system_error = 0, exit_code = 0;
    size_t output_size = 0, diagnostic_size = 0;
    wchar_t environment[(MAX_PATH + 1) * 4 + 64] = {0};
    if (status != MC_PLUGIN_PROCESS_RUNNING) goto cleanup;
    if (!child_environment(environment, sizeof(environment) / sizeof(environment[0])) ||
        !pipe_pair(&input_read, &input_write, &input_write) ||
        !pipe_pair(&output_read, &output_write, &output_read) ||
        !pipe_pair(&error_read, &error_write, &error_read)) goto launch_failure;
    job = CreateJobObjectW(NULL, NULL);
    if (!job) goto launch_failure;
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {0};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE |
                                             JOB_OBJECT_LIMIT_ACTIVE_PROCESS;
    limits.BasicLimitInformation.ActiveProcessLimit = 1;
    if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits,
                                 sizeof(limits))) goto launch_failure;
    SIZE_T attribute_size = 0;
    InitializeProcThreadAttributeList(NULL, 2, 0, &attribute_size);
    if (!attribute_size) goto launch_failure;
    attributes = malloc(attribute_size);
    if (!attributes) {
        SetLastError(ERROR_NOT_ENOUGH_MEMORY);
        goto launch_failure;
    }
    if (!InitializeProcThreadAttributeList(attributes, 2, 0, &attribute_size)) goto launch_failure;
    attributes_initialized = 1;
    HANDLE inherited[3] = { input_read, output_write, error_write };
    if (!UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                                   inherited, sizeof(inherited), NULL, NULL)) goto launch_failure;
    /* Atomic assignment prevents a suspended orphan if the application exits
     * between CreateProcess and a separate AssignProcessToJobObject call. */
    if (!UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_JOB_LIST,
                                   &job, sizeof(job), NULL, NULL)) goto launch_failure;
    startup.StartupInfo.cb = sizeof(startup);
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
    startup.StartupInfo.wShowWindow = SW_HIDE;
    startup.StartupInfo.hStdInput = input_read;
    startup.StartupInfo.hStdOutput = output_write;
    startup.StartupInfo.hStdError = error_write;
    startup.lpAttributeList = attributes;
    status = interruption(process);
    if (status != MC_PLUGIN_PROCESS_RUNNING) goto cleanup;
    if (!CreateProcessW(process->executable, process->command_line, NULL, NULL, TRUE,
                        CREATE_SUSPENDED | CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT |
                        EXTENDED_STARTUPINFO_PRESENT, environment, process->directory,
                        &startup.StartupInfo, &child)) goto launch_failure;
    /* Job-list assignment is part of creation on our Win10+ baseline. Neither
     * breakaway flag is enabled, and no child inherits the job handle. */
    close_handle(&input_read);
    close_handle(&output_write);
    close_handle(&error_write);
    status = interruption(process);
    if (status != MC_PLUGIN_PROCESS_RUNNING) goto communicate;
    if (ResumeThread(child.hThread) == (DWORD)-1) goto launch_failure;
    close_handle(&child.hThread);
    writer.pipe = input_write;
    writer.cancelled = process->cancelled;
    writer.bytes = process->payload;
    writer.size = process->payload_size;
    writer_thread = CreateThread(NULL, 0, write_input, &writer, 0, NULL);
    if (!writer_thread) goto launch_failure;
    input_write = NULL; /* Writer now exclusively owns and closes this handle. */

communicate:
    for (;;) {
        MCPluginProcessStatus interrupted = interruption(process);
        if (interrupted != MC_PLUGIN_PROCESS_RUNNING)
            fail_once(&status, &system_error, interrupted, 0);
        drain_pipe(&output_read, process->output, process->output_capacity, &output_size,
                   &status, &system_error);
        drain_pipe(&error_read, process->diagnostics, process->diagnostic_capacity, &diagnostic_size,
                   &status, &system_error);
        if (status != MC_PLUGIN_PROCESS_RUNNING && !terminating) {
            terminating = 1;
            /* Cancellation marks IO only; completion is awaited below. Job
             * termination closes the child's read end even if no write was
             * pending at the exact instant CancelSynchronousIo was called. */
            if (!TerminateJobObject(job, ERROR_OPERATION_ABORTED) && !system_error)
                system_error = GetLastError();
            if (!TerminateProcess(child.hProcess, ERROR_OPERATION_ABORTED)) {
                DWORD terminate_error = GetLastError();
                if (WaitForSingleObject(child.hProcess, 0) != WAIT_OBJECT_0 && !system_error)
                    system_error = terminate_error;
            }
            if (writer_thread) CancelSynchronousIo(writer_thread);
            close_handle(&input_write);
        }
        DWORD child_wait = WaitForSingleObject(child.hProcess, 0);
        DWORD writer_wait = writer_thread ? WaitForSingleObject(writer_thread, 0) : WAIT_OBJECT_0;
        if (child_wait == WAIT_FAILED || writer_wait == WAIT_FAILED) {
            fail_once(&status, &system_error, MC_PLUGIN_PROCESS_IO_FAILED, GetLastError());
        }
        if (child_wait == WAIT_OBJECT_0 && writer_wait == WAIT_OBJECT_0 &&
            !output_read && !error_read) break;
        /* No busy loop on a signaled cancel/process event during final drain. */
        if (terminating) Sleep(2);
        else WaitForSingleObject(process->cancelled, 2);
    }
    if (!GetExitCodeProcess(child.hProcess, &exit_code))
        fail_once(&status, &system_error, MC_PLUGIN_PROCESS_IO_FAILED, GetLastError());
    if (status == MC_PLUGIN_PROCESS_RUNNING) {
        if (exit_code) status = MC_PLUGIN_PROCESS_EXECUTION_FAILED;
        else if (writer.error) {
            status = MC_PLUGIN_PROCESS_IO_FAILED;
            system_error = writer.error;
        } else status = MC_PLUGIN_PROCESS_OK;
    }
    goto cleanup;

launch_failure:
    fail_once(&status, &system_error, MC_PLUGIN_PROCESS_LAUNCH_FAILED, GetLastError());
    if (child.hProcess) {
        /* Even a suspended child is already owned by this private job. */
        TerminateJobObject(job, ERROR_OPERATION_ABORTED);
        TerminateProcess(child.hProcess, ERROR_OPERATION_ABORTED);
        close_handle(&input_read);
        close_handle(&output_write);
        close_handle(&error_write);
        goto communicate;
    }

cleanup:
    close_handle(&input_read);
    close_handle(&input_write);
    close_handle(&output_read);
    close_handle(&output_write);
    close_handle(&error_read);
    close_handle(&error_write);
    close_handle(&writer_thread);
    close_handle(&child.hThread);
    close_handle(&child.hProcess);
    close_handle(&job);
    if (attributes_initialized) DeleteProcThreadAttributeList(attributes);
    free(attributes);
    free(process->payload);
    process->payload = NULL;
    process->result.output = status == MC_PLUGIN_PROCESS_OK ? process->output : NULL;
    process->result.output_size = status == MC_PLUGIN_PROCESS_OK ? output_size : 0;
    process->result.diagnostics = process->diagnostics;
    process->result.diagnostics_size = diagnostic_size;
    process->result.exit_code = exit_code;
    process->result.system_error = system_error;
    process->status = status;
    /* poll exposes these fields only after this thread itself is signaled. */
    return 0;
}

static void free_process(MCPluginProcess *process) {
    if (!process) return;
    close_handle(&process->controller);
    close_handle(&process->cancelled);
    free(process->executable);
    free(process->directory);
    free(process->command_line);
    free(process->payload);
    free(process->output);
    free(process->diagnostics);
    free(process);
}

MCPluginProcess *mc_plugin_process_start(const MCPluginProcessRequest *request) {
    if (!request) return NULL;
    MCPluginProcess *process = calloc(1, sizeof(*process));
    if (!process) return NULL;
    process->started = GetTickCount64();
    if (!mc_plugin_process_prepare(request, &process->payload, &process->payload_size) ||
        !copy_executable(process, request->executable)) goto failed;
    process->output_capacity = request->wire.max_output_bytes;
    process->diagnostic_capacity = request->max_stderr_bytes;
    process->wall_ms = request->wall_ms;
    process->output = malloc(process->output_capacity);
    process->diagnostics = malloc(process->diagnostic_capacity ? process->diagnostic_capacity : 1u);
    process->cancelled = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!process->output || !process->diagnostics || !process->cancelled) goto failed;
    process->controller = CreateThread(NULL, 0, control_process, process, 0, NULL);
    if (!process->controller) goto failed;
    return process;
failed:
    free_process(process);
    return NULL;
}

MCPluginProcessStatus mc_plugin_process_poll(MCPluginProcess *process, MCPluginProcessResult *result) {
    if (result) memset(result, 0, sizeof(*result));
    if (!process) return MC_PLUGIN_PROCESS_LAUNCH_FAILED;
    if (WaitForSingleObject(process->controller, 0) != WAIT_OBJECT_0)
        return MC_PLUGIN_PROCESS_RUNNING;
    if (result) *result = process->result;
    return process->status;
}

void mc_plugin_process_cancel(MCPluginProcess *process) {
    if (process && WaitForSingleObject(process->controller, 0) != WAIT_OBJECT_0)
        SetEvent(process->cancelled);
}

int mc_plugin_process_close(MCPluginProcess *process) {
    if (!process || WaitForSingleObject(process->controller, 0) != WAIT_OBJECT_0) return 0;
    free_process(process);
    return 1;
}
