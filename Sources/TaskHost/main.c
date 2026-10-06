//
//  main.c
//  TaskHost
//
//  Created by Василий Маслов on 01.10.2026.
// A per-task supervisor. stdout is PTY output or framed pipe streams; stderr contains JSON lifecycle events.
#include <util.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <sys/poll.h>
#include <libproc.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct { pid_t pid; uint64_t seconds, micros; } Identity;
static Identity *owned;
static size_t ownedCount;
static pid_t leader;
static volatile sig_atomic_t interrupted;
static double monotonicTime(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec + ts.tv_nsec / 1e9; }
static void onSignal(int sig) { (void)sig; interrupted = 1; }
static int identity(pid_t pid, Identity *result, pid_t *parent) {
    struct proc_bsdinfo info;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) || info.pbi_uid != getuid()) return 0;
    *result = (Identity){pid, info.pbi_start_tvsec, info.pbi_start_tvusec};
    if (parent) *parent = info.pbi_ppid;
    return 1;
}
static int equal(Identity first, Identity second) { return first.pid == second.pid && first.seconds == second.seconds && first.micros == second.micros; }
static int known(pid_t pid) {
    Identity current;
    if (!identity(pid, &current, NULL)) return 0;
    for (size_t index = 0; index < ownedCount; index++) if (equal(current, owned[index])) return 1;
    return 0;
}
// Session membership catches orphaned shell children; parent identity catches new groups/sessions.
static void collectChildren(void) {
    int capacity = proc_listallpids(NULL, 0) + 128;
    if (capacity <= 128) return;
    pid_t *pids = calloc((size_t)capacity, sizeof(pid_t));
    int count = proc_listallpids(pids, capacity * (int)sizeof(pid_t));
    for (int pass = 0; pass < 3; pass++) for (int index = 0; index < count; index++) {
        Identity current; pid_t parent;
        if (pids[index] <= 0 || pids[index] == getpid() || known(pids[index])) continue;
        if (!identity(pids[index], &current, &parent)) continue;
        if (getsid(current.pid) != leader && !known(parent)) continue;
        Identity *next = realloc(owned, (ownedCount + 1) * sizeof(Identity));
        if (!next) continue;
        owned = next; owned[ownedCount++] = current;
    }
    free(pids);
}
static int signalOwned(int sig) {
    int alive = 0;
    for (size_t index = 0; index < ownedCount; index++) {
        Identity current;
        if (identity(owned[index].pid, &current, NULL) && equal(current, owned[index])) {
            if (sig) kill(current.pid, sig);
            alive++;
        }
    }
    return alive;
}
static int writeAll(int fd, const void *buffer, size_t length) {
    const char *bytes = buffer;
    while (length) { ssize_t count = write(fd, bytes, length); if (count < 0 && errno == EINTR) continue; if (count <= 0) return -1; bytes += count; length -= (size_t)count; }
    return 0;
}
static uint32_t decode32(const uint8_t *bytes) { return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) | ((uint32_t)bytes[2] << 8) | bytes[3]; }
// Pipe mode multiplexes child stdout/stderr without contaminating the JSON lifecycle channel.
static int forwardOutput(int kind, const uint8_t *bytes, size_t length, int framed) {
    if (framed) {
        uint8_t header[5] = {(uint8_t)kind, (uint8_t)(length >> 24), (uint8_t)(length >> 16), (uint8_t)(length >> 8), (uint8_t)length};
        if (writeAll(STDOUT_FILENO, header, sizeof(header))) return -1;
    }
    return writeAll(STDOUT_FILENO, bytes, length);
}

int main(int argc, char **argv) {
    int pipeMode = argc > 1 && !strcmp(argv[1], "--pipes");
    if (pipeMode) { argv++; argc--; }
    if (argc < 5 || strcmp(argv[1], "--cwd") || strcmp(argv[3], "--")) return 2;
    signal(SIGPIPE, SIG_IGN); signal(SIGTERM, onSignal); signal(SIGINT, onSignal); signal(SIGHUP, onSignal);
    int execPipe[2];
    if (pipe(execPipe)) { fprintf(stderr, "{\"kind\":\"error\",\"errno\":%d}\n", errno); return 1; }
    fcntl(execPipe[1], F_SETFD, FD_CLOEXEC);
    struct winsize window = {.ws_row = 30, .ws_col = 100}; int master = -1, childInput = -1, childError = -1;
    int stdinPipe[2] = {-1, -1}, stdoutPipe[2] = {-1, -1}, stderrPipe[2] = {-1, -1};
    if (pipeMode && (pipe(stdinPipe) || pipe(stdoutPipe) || pipe(stderrPipe))) return 1;
    leader = pipeMode ? fork() : forkpty(&master, NULL, NULL, &window);
    if (leader < 0) { fprintf(stderr, "{\"kind\":\"error\",\"errno\":%d}\n", errno); return 1; }
    if (leader == 0) {
        close(execPipe[0]);
        if (pipeMode) {
            setsid();
            dup2(stdinPipe[0], STDIN_FILENO); dup2(stdoutPipe[1], STDOUT_FILENO); dup2(stderrPipe[1], STDERR_FILENO);
            close(stdinPipe[0]); close(stdinPipe[1]); close(stdoutPipe[0]); close(stdoutPipe[1]); close(stderrPipe[0]); close(stderrPipe[1]);
        }
        // The child uses only async-signal-safe operations before exec.
        if (chdir(argv[2]) == 0) execv(argv[4], &argv[4]);
        int code = errno; write(execPipe[1], &code, sizeof(code)); _exit(127);
    }
    if (pipeMode) {
        close(stdinPipe[0]); close(stdoutPipe[1]); close(stderrPipe[1]);
        master = stdoutPipe[0]; childInput = stdinPipe[1]; childError = stderrPipe[0];
        fcntl(childInput, F_SETFL, O_NONBLOCK); fcntl(childError, F_SETFL, O_NONBLOCK);
    } else childInput = master;
    close(execPipe[1]); fcntl(execPipe[0], F_SETFL, O_NONBLOCK); fcntl(master, F_SETFL, O_NONBLOCK);
    owned = malloc(sizeof(Identity)); ownedCount = identity(leader, owned, NULL) ? 1 : 0;
    fprintf(stderr, "{\"kind\":\"started\",\"pid\":%d}\n", leader); fflush(stderr);
    uint8_t input[1048581]; size_t inputCount = 0;
    uint8_t pending[1048576]; size_t pendingCount = 0, pendingOffset = 0; int closeInputWhenDrained = 0;
    int rootExited = 0, status = 0, cancellation = 0, phase = 0, outputOpen = 1, parentOpen = 1, launchError = 0, execReady = 0;
    double cancelledAt = 0, exitedAt = 0;
    for (;;) {
        if (!rootExited) collectChildren();
        if (interrupted && !cancellation) { cancellation = 1; cancelledAt = monotonicTime(); if (execReady) signalOwned(SIGINT); }
        double elapsed = cancellation ? monotonicTime() - cancelledAt : 0;
        if (cancellation && elapsed >= 5 && phase == 0) { signalOwned(SIGTERM); phase = 1; }
        if (cancellation && elapsed >= 10 && phase == 1) { signalOwned(SIGKILL); phase = 2; }
        struct pollfd descriptors[5] = {{outputOpen ? master : -1, POLLIN, 0}, {parentOpen ? STDIN_FILENO : -1, POLLIN, 0}, {execPipe[0], POLLIN, 0}, {childError, POLLIN, 0}, {pipeMode && pendingCount > pendingOffset ? childInput : -1, POLLOUT, 0}};
        poll(descriptors, 5, 40);
        if (descriptors[2].revents & POLLIN) {
            int code = 0;
            if (read(execPipe[0], &code, sizeof(code)) == sizeof(code)) { launchError = code; fprintf(stderr, "{\"kind\":\"error\",\"errno\":%d}\n", code); fflush(stderr); }
        }
        if (descriptors[2].revents & POLLHUP) {
            close(execPipe[0]); execPipe[0] = -1; execReady = 1;
            // A pre-exec child still has our signal handler. Deliver pending cancellation after exec resets it.
            if (cancellation) { collectChildren(); signalOwned(SIGINT); }
        }
        if (descriptors[0].revents & (POLLIN | POLLHUP | POLLERR)) {
            uint8_t buffer[16384]; ssize_t count;
            while ((count = read(master, buffer, sizeof(buffer))) > 0) if (forwardOutput(1, buffer, (size_t)count, pipeMode)) interrupted = 1;
            if (count == 0 || (count < 0 && errno == EIO)) outputOpen = 0;
        }
        if (descriptors[3].revents & (POLLIN | POLLHUP | POLLERR)) {
            uint8_t buffer[16384]; ssize_t count;
            while ((count = read(childError, buffer, sizeof(buffer))) > 0) if (forwardOutput(2, buffer, (size_t)count, 1)) interrupted = 1;
            if (count == 0) { close(childError); childError = -1; }
        }
        // Pipe input progresses alongside both output streams, even when a provider emits startup JSON first.
        if (descriptors[4].revents & (POLLOUT | POLLHUP | POLLERR)) {
            ssize_t amount = write(childInput, pending + pendingOffset, pendingCount - pendingOffset);
            if (amount > 0) pendingOffset += (size_t)amount;
            else if (amount < 0 && errno != EAGAIN && errno != EINTR) { close(childInput); childInput = -1; }
        }
        if (descriptors[1].revents & (POLLIN | POLLHUP)) {
            ssize_t count = read(STDIN_FILENO, input + inputCount, sizeof(input) - inputCount);
            if (count <= 0) { parentOpen = 0; interrupted = 1; } else inputCount += (size_t)count;
            size_t offset = 0;
            while (inputCount - offset >= 5) {
                uint8_t kind = input[offset]; uint32_t length = decode32(input + offset + 1);
                if (length > 1048576) { interrupted = 1; parentOpen = 0; inputCount = 0; break; }
                if (inputCount - offset < length + 5) break;
                const uint8_t *payload = input + offset + 5;
                if (kind == 1 && !rootExited && childInput >= 0) {
                    if (pipeMode) {
                        if (pendingOffset) { memmove(pending, pending + pendingOffset, pendingCount - pendingOffset); pendingCount -= pendingOffset; pendingOffset = 0; }
                        if (length > sizeof(pending) - pendingCount) interrupted = 1;
                        else { memcpy(pending + pendingCount, payload, length); pendingCount += length; }
                    } else {
                    // Bounded PTY writes; stop waiting as soon as cancellation arrives.
                    size_t sent = 0;
                    while (sent < length && !interrupted) {
                        ssize_t amount = write(childInput, payload + sent, length - sent);
                        if (amount > 0) sent += (size_t)amount;
                        else if (errno == EAGAIN || errno == EINTR) {
                            struct pollfd writable[2] = {{childInput, POLLOUT, 0}, {STDIN_FILENO, 0, 0}};
                            poll(writable, 2, 40);
                            if (writable[1].revents & (POLLHUP | POLLERR)) interrupted = 1;
                        }
                        else break;
                    }
                    }
                } else if (kind == 2 && length == 4 && !pipeMode) {
                    window.ws_col = (payload[0] << 8) | payload[1]; window.ws_row = (payload[2] << 8) | payload[3];
                    if (window.ws_col && window.ws_row) ioctl(master, TIOCSWINSZ, &window);
                } else if (kind == 3) interrupted = 1;
                else if (kind == 4 && pipeMode) closeInputWhenDrained = 1;
                offset += length + 5;
            }
            if (offset <= inputCount) { memmove(input, input + offset, inputCount - offset); inputCount -= offset; }
        }
        if (pipeMode && pendingOffset == pendingCount) {
            pendingCount = 0; pendingOffset = 0;
            if (closeInputWhenDrained && childInput >= 0) { close(childInput); childInput = -1; }
        }
        if (!rootExited) {
            pid_t result = waitpid(leader, &status, WNOHANG);
            if (result == leader) { rootExited = 1; exitedAt = monotonicTime(); }
        }
        if (rootExited) {
            int remaining = signalOwned(0);
            if (remaining && !cancellation) { cancellation = 1; cancelledAt = monotonicTime(); signalOwned(SIGTERM); }
            if (!remaining && ((!outputOpen && childError < 0) || monotonicTime() - exitedAt > 0.5)) break;
            if (cancellation && elapsed > 11) break;
        }
    }
    if (master >= 0) close(master);
    if (pipeMode && childInput >= 0) close(childInput);
    if (childError >= 0) close(childError);
    if (execPipe[0] >= 0) close(execPipe[0]);
    fprintf(stderr, "{\"kind\":\"exit\",\"code\":%d,\"signal\":%d,\"cancelled\":%s,\"launchError\":%d}\n", WIFEXITED(status) ? WEXITSTATUS(status) : -1, WIFSIGNALED(status) ? WTERMSIG(status) : 0, interrupted ? "true" : "false", launchError);
    free(owned);
    return 0;
}
