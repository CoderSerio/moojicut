#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "worker_process_internal.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

enum { IO_CHUNK = 4096, IO_BATCH = 16, POLL_MS = 20, TERM_GRACE_MS = 250, PATH_CAP = 4096 };

struct MCPluginProcess {
    pthread_mutex_t mutex;
    MCPluginProcessStatus published;
    int cancelled;
    char *executable;
    uint8_t *payload, *output, *diagnostics;
    size_t payload_size, output_size, diagnostics_size, output_cap, diagnostics_cap;
    uint64_t deadline_ns;
    uint32_t exit_code, system_error;
};

static uint64_t monotonic_ns(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now)) return 0;
    return (uint64_t)now.tv_sec * UINT64_C(1000000000) + (uint64_t)now.tv_nsec;
}
static void close_fd(int *fd) {
    if (*fd >= 0) { close(*fd); *fd = -1; }
}
static int absolute_utf8_path(const char *path, size_t *length) {
    if (!path || path[0] != '/') return 0;
    size_t size = strnlen(path, PATH_CAP + 1u);
    if (!size || size > PATH_CAP) return 0;
    for (size_t i = 0; i < size;) {
        uint8_t b = (uint8_t)path[i++];
        if (b < 0x80) continue;
        unsigned extra;
        uint32_t value, minimum;
        if (b >= 0xc2 && b <= 0xdf) { extra = 1; value = b & 0x1fu; minimum = 0x80; }
        else if (b >= 0xe0 && b <= 0xef) { extra = 2; value = b & 0x0fu; minimum = 0x800; }
        else if (b >= 0xf0 && b <= 0xf4) { extra = 3; value = b & 7u; minimum = 0x10000; }
        else return 0;
        if (extra > size - i) return 0;
        for (unsigned j = 0; j < extra; j++) {
            b = (uint8_t)path[i++];
            if ((b & 0xc0) != 0x80) return 0;
            value = (value << 6) | (b & 0x3fu);
        }
        if (value < minimum || value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) return 0;
    }
    *length = size;
    return 1;
}
static int pipe_owned(int fds[2]) {
#if defined(__APPLE__)
    if (pipe(fds)) return errno;
    if (fcntl(fds[0], F_SETFD, FD_CLOEXEC) < 0 || fcntl(fds[1], F_SETFD, FD_CLOEXEC) < 0) {
        int error = errno; close_fd(&fds[0]); close_fd(&fds[1]); return error;
    }
#else
    if (pipe2(fds, O_CLOEXEC)) return errno;
#endif
    /* If the app has closed a standard descriptor, do not let the dup2 actions
     * accidentally overwrite another pipe endpoint during child setup. */
    for (unsigned i = 0; i < 2; i++) {
        if (fds[i] < 3) {
            int elevated = fcntl(fds[i], F_DUPFD_CLOEXEC, 3);
            if (elevated < 0) { int error = errno; close_fd(&fds[0]); close_fd(&fds[1]); return error; }
            close_fd(&fds[i]); fds[i] = elevated;
        }
    }
    return 0;
}
static int nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL);
    return flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 ? errno : 0;
}
static int requested_cancel(MCPluginProcess *process) {
    pthread_mutex_lock(&process->mutex);
    int cancelled = process->cancelled;
    pthread_mutex_unlock(&process->mutex);
    return cancelled;
}
static void set_failure(MCPluginProcess *process, MCPluginProcessStatus *status,
                        MCPluginProcessStatus failure, int error) {
    if (*status == MC_PLUGIN_PROCESS_RUNNING) {
        *status = failure;
        process->system_error = (uint32_t)error;
    }
}

static int spawn_child(MCPluginProcess *process, pid_t *pid, int *input, int *output, int *diagnostic) {
    int in[2] = {-1, -1}, out[2] = {-1, -1}, err[2] = {-1, -1};
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int have_actions = 0, have_attributes = 0;
    int error = pipe_owned(in);
    if (error || (error = pipe_owned(out)) || (error = pipe_owned(err))) goto cleanup;
    if ((error = nonblocking(in[1])) || (error = nonblocking(out[0])) || (error = nonblocking(err[0]))) goto cleanup;
#if defined(__APPLE__)
    /* Use Darwin's per-descriptor suppression for writes racing child exit;
     * this preserves every application-global signal handler. */
    if (fcntl(in[1], F_SETNOSIGPIPE, 1) < 0) { error = errno; goto cleanup; }
#endif
    if ((error = posix_spawn_file_actions_init(&actions))) goto cleanup;
    have_actions = 1;
    if ((error = posix_spawnattr_init(&attributes))) goto cleanup;
    have_attributes = 1;
    if ((error = posix_spawn_file_actions_adddup2(&actions, in[0], STDIN_FILENO)) ||
        (error = posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO)) ||
        (error = posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO))) goto cleanup;
#if defined(__APPLE__)
    /* This spelling remains available on pre-26 macOS; the standard spelling
     * was only added in macOS 26. Keep compatibility without process chdir. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    error = posix_spawn_file_actions_addchdir_np(&actions, "/");
#pragma clang diagnostic pop
    short flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT;
#else
    error = posix_spawn_file_actions_addchdir_np(&actions, "/");
    if (!error) error = posix_spawn_file_actions_addclosefrom_np(&actions, 3);
    short flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF;
#endif
    if (error) goto cleanup;
    sigset_t mask, defaults;
    sigemptyset(&mask); sigemptyset(&defaults);
    sigaddset(&defaults, SIGPIPE); sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGINT); sigaddset(&defaults, SIGHUP);
    if ((error = posix_spawnattr_setflags(&attributes, flags)) ||
        (error = posix_spawnattr_setpgroup(&attributes, 0)) ||
        (error = posix_spawnattr_setsigmask(&attributes, &mask)) ||
        (error = posix_spawnattr_setsigdefault(&attributes, &defaults))) goto cleanup;
    char *arguments[] = {process->executable, NULL};
    char path[] = "PATH=/usr/bin:/bin", lang[] = "LANG=en_US.UTF-8";
    char *environment[] = {path, lang, NULL};
    error = posix_spawn(pid, process->executable, &actions, &attributes, arguments, environment);
    if (!error) {
        *input = in[1]; in[1] = -1;
        *output = out[0]; out[0] = -1;
        *diagnostic = err[0]; err[0] = -1;
    }
cleanup:
    if (have_attributes) posix_spawnattr_destroy(&attributes);
    if (have_actions) posix_spawn_file_actions_destroy(&actions);
    for (unsigned i = 0; i < 2; i++) { close_fd(&in[i]); close_fd(&out[i]); close_fd(&err[i]); }
    return error;
}

static void read_stream(MCPluginProcess *process, int *fd, int diagnostic, MCPluginProcessStatus *status) {
    uint8_t *buffer = diagnostic ? process->diagnostics : process->output;
    size_t *size = diagnostic ? &process->diagnostics_size : &process->output_size;
    size_t cap = diagnostic ? process->diagnostics_cap : process->output_cap;
    for (unsigned i = 0; *fd >= 0 && i < IO_BATCH; i++) {
        uint8_t bytes[IO_CHUNK];
        ssize_t count = read(*fd, bytes, sizeof(bytes));
        if (count > 0) {
            if ((size_t)count > cap - *size) set_failure(process, status, MC_PLUGIN_PROCESS_LIMIT_EXCEEDED, 0);
            else if (*status == MC_PLUGIN_PROCESS_RUNNING) {
                memcpy(buffer + *size, bytes, (size_t)count); *size += (size_t)count;
            }
        } else if (!count) close_fd(fd);
        else if (errno == EAGAIN || errno == EWOULDBLOCK) break;
        else if (errno != EINTR) {
            set_failure(process, status, MC_PLUGIN_PROCESS_IO_FAILED, errno);
            close_fd(fd);
        }
    }
}
static void discard_input(MCPluginProcess *process, int *fd) {
    close_fd(fd);
    free(process->payload); process->payload = NULL; process->payload_size = 0;
}
static void signal_group(pid_t pid, int signal_number) {
    /* The leader remains unreaped until the final cleanup below, preventing
     * reuse of its PID/group ID while cancellation is in flight. */
    if (pid > 0) { (void)kill(-pid, signal_number); (void)kill(pid, signal_number); }
}
static void *coordinate(void *context) {
    MCPluginProcess *process = context;
    MCPluginProcessStatus status = MC_PLUGIN_PROCESS_RUNNING;
    pid_t pid = -1;
    int input = -1, output = -1, diagnostic = -1;
    int child_exited = 0, child_reaped = 0, term_sent = 0, kill_sent = 0;
    uint64_t term_ns = 0, kill_ns = 0;
    size_t written = 0;
    /* A dedicated thread can keep SIGPIPE blocked for its whole lifetime. No
     * application-global signal handler changes, nor a borrowed GUI thread's
     * signal mask. The child receives its own explicit empty mask. */
    sigset_t blocked;
    sigemptyset(&blocked); sigaddset(&blocked, SIGPIPE);
    int error = pthread_sigmask(SIG_BLOCK, &blocked, NULL);
    if (error) { set_failure(process, &status, MC_PLUGIN_PROCESS_IO_FAILED, error); goto finish; }
    if (requested_cancel(process)) { status = MC_PLUGIN_PROCESS_CANCELLED; goto finish; }
    if (monotonic_ns() >= process->deadline_ns) { status = MC_PLUGIN_PROCESS_TIMED_OUT; goto finish; }
    error = spawn_child(process, &pid, &input, &output, &diagnostic);
    if (error) {
        if (requested_cancel(process)) status = MC_PLUGIN_PROCESS_CANCELLED;
        else if (monotonic_ns() >= process->deadline_ns) status = MC_PLUGIN_PROCESS_TIMED_OUT;
        else status = MC_PLUGIN_PROCESS_LAUNCH_FAILED;
        process->system_error = (uint32_t)error;
        goto finish;
    }
    for (;;) {
        uint64_t now = monotonic_ns();
        if (!now) set_failure(process, &status, MC_PLUGIN_PROCESS_IO_FAILED, errno);
        if (requested_cancel(process)) set_failure(process, &status, MC_PLUGIN_PROCESS_CANCELLED, 0);
        if (now >= process->deadline_ns) set_failure(process, &status, MC_PLUGIN_PROCESS_TIMED_OUT, 0);
        if (status != MC_PLUGIN_PROCESS_RUNNING && !term_sent) {
            discard_input(process, &input); signal_group(pid, SIGTERM); term_sent = 1; term_ns = now;
        }
        if (term_sent && !kill_sent && now - term_ns >= (uint64_t)TERM_GRACE_MS * 1000000) {
            signal_group(pid, SIGKILL); kill_sent = 1; kill_ns = now;
        }
        if (input >= 0 && status == MC_PLUGIN_PROCESS_RUNNING) {
            size_t remaining = process->payload_size - written;
            ssize_t count = write(input, process->payload + written, remaining < 65536 ? remaining : 65536);
            if (count > 0) written += (size_t)count;
            else if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
                set_failure(process, &status, MC_PLUGIN_PROCESS_IO_FAILED, errno);
            if (written == process->payload_size) discard_input(process, &input);
        }
        read_stream(process, &output, 0, &status);
        read_stream(process, &diagnostic, 1, &status);
        if (!child_exited) {
            siginfo_t info;
            memset(&info, 0, sizeof(info));
            if (!waitid(P_PID, (id_t)pid, &info, WEXITED | WNOHANG | WNOWAIT)) {
                if (info.si_pid == pid) {
                    child_exited = 1;
                    process->exit_code = info.si_code == CLD_EXITED ? (uint32_t)info.si_status : (uint32_t)(128 + info.si_status);
                    discard_input(process, &input);
                    /* A descendant must not keep inherited pipes alive after
                     * the owned leader exits, even on a nominal success. */
                    signal_group(pid, SIGKILL); kill_sent = 1; kill_ns = now;
                }
            } else if (errno != EINTR) {
                error = errno;
                set_failure(process, &status, MC_PLUGIN_PROCESS_IO_FAILED, error);
                if (error == ECHILD) {
                    /* Another reaper invalidated our ownership: never signal
                     * a potentially recycled PID. No success can be exposed. */
                    pid = -1; child_exited = child_reaped = 1;
                    discard_input(process, &input); close_fd(&output); close_fd(&diagnostic);
                }
            }
        }
        if (kill_sent && child_exited && (output >= 0 || diagnostic >= 0) &&
            now - kill_ns >= (uint64_t)TERM_GRACE_MS * 1000000) {
            /* A pipe could escape the group through an independently reparented
             * process. Bound draining; an incomplete drain is always failure. */
            set_failure(process, &status, MC_PLUGIN_PROCESS_IO_FAILED, ETIMEDOUT);
            close_fd(&output); close_fd(&diagnostic);
        }
        if (child_exited && output < 0 && diagnostic < 0) break;
        struct pollfd fds[3] = {{input, POLLOUT, 0}, {output, POLLIN, 0}, {diagnostic, POLLIN, 0}};
        if (poll(fds, 3, POLL_MS) < 0 && errno != EINTR)
            set_failure(process, &status, MC_PLUGIN_PROCESS_IO_FAILED, errno);
    }
    if (!child_reaped) {
        int wait_status;
        pid_t waited;
        do { waited = waitpid(pid, &wait_status, 0); } while (waited < 0 && errno == EINTR);
        if (waited != pid) set_failure(process, &status, MC_PLUGIN_PROCESS_IO_FAILED, errno);
    }
    if (status == MC_PLUGIN_PROCESS_RUNNING)
        status = process->exit_code ? MC_PLUGIN_PROCESS_EXECUTION_FAILED : MC_PLUGIN_PROCESS_OK;
finish:
    discard_input(process, &input); close_fd(&output); close_fd(&diagnostic);
    free(process->executable); process->executable = NULL;
    pthread_mutex_lock(&process->mutex);
    process->published = status;
    pthread_mutex_unlock(&process->mutex);
    /* Detached thread: no process/object access after publishing terminal. */
    return NULL;
}

MCPluginProcess *mc_plugin_process_start(const MCPluginProcessRequest *request) {
    size_t path_size;
    if (!request || !absolute_utf8_path(request->executable, &path_size)) return NULL;
    struct sigaction child_action;
    if (sigaction(SIGCHLD, NULL, &child_action) || child_action.sa_handler == SIG_IGN || (child_action.sa_flags & SA_NOCLDWAIT)) return NULL;
    uint64_t started = monotonic_ns();
    if (!started) return NULL;
    MCPluginProcess *process = calloc(1, sizeof(*process));
    if (!process) return NULL;
    if (!mc_plugin_process_prepare(request, &process->payload, &process->payload_size)) goto fail;
    process->executable = malloc(path_size + 1);
    process->output_cap = request->wire.max_output_bytes;
    process->diagnostics_cap = request->max_stderr_bytes;
    process->output = malloc(process->output_cap);
    process->diagnostics = malloc(process->diagnostics_cap);
    if (!process->executable || !process->output || !process->diagnostics) goto fail;
    memcpy(process->executable, request->executable, path_size + 1);
    process->deadline_ns = started + (uint64_t)request->wall_ms * 1000000;
    if (pthread_mutex_init(&process->mutex, NULL)) goto fail;
    pthread_attr_t attributes;
    if (pthread_attr_init(&attributes)) { pthread_mutex_destroy(&process->mutex); goto fail; }
    int error = pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
    pthread_t thread;
    if (!error) error = pthread_create(&thread, &attributes, coordinate, process);
    pthread_attr_destroy(&attributes);
    if (error) { pthread_mutex_destroy(&process->mutex); goto fail; }
    return process;
fail:
    free(process->executable); free(process->payload); free(process->output); free(process->diagnostics); free(process);
    return NULL;
}
MCPluginProcessStatus mc_plugin_process_poll(MCPluginProcess *process, MCPluginProcessResult *result) {
    if (result) memset(result, 0, sizeof(*result));
    if (!process) return MC_PLUGIN_PROCESS_LAUNCH_FAILED;
    pthread_mutex_lock(&process->mutex);
    MCPluginProcessStatus status = process->published;
    if (result && status != MC_PLUGIN_PROCESS_RUNNING) {
        result->output = status == MC_PLUGIN_PROCESS_OK ? process->output : NULL;
        result->output_size = status == MC_PLUGIN_PROCESS_OK ? process->output_size : 0;
        result->diagnostics = process->diagnostics; result->diagnostics_size = process->diagnostics_size;
        result->exit_code = process->exit_code; result->system_error = process->system_error;
    }
    pthread_mutex_unlock(&process->mutex);
    return status;
}
void mc_plugin_process_cancel(MCPluginProcess *process) {
    if (!process) return;
    pthread_mutex_lock(&process->mutex);
    if (process->published == MC_PLUGIN_PROCESS_RUNNING) process->cancelled = 1;
    pthread_mutex_unlock(&process->mutex);
}
int mc_plugin_process_close(MCPluginProcess *process) {
    if (!process) return 1;
    pthread_mutex_lock(&process->mutex);
    int terminal = process->published != MC_PLUGIN_PROCESS_RUNNING;
    pthread_mutex_unlock(&process->mutex);
    if (!terminal) return 0;
    pthread_mutex_destroy(&process->mutex);
    free(process->output); free(process->diagnostics); free(process);
    return 1;
}
