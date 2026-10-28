#define _POSIX_C_SOURCE 200809L
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* Independent lifetime owner. A crashed GUI cannot run its own cleanup handler.
 * No shell is used, every child lives in its own process group, and cleanup
 * targets only the exact endpoint supplied by the owning session. */
static volatile sig_atomic_t stopping = 0;
static volatile sig_atomic_t stop_signal = 0;
static void request_stop(int signo) { stop_signal = signo; stopping = 1; }
static void pause_tick(void) { struct timespec delay = {0, 50000000}; nanosleep(&delay, NULL); }
static double monotonic_seconds(void) {
    struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
    return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
}
static pid_t launch_output(char *const args[], int output) {
    pid_t pid = fork();
    if (pid == 0) {
        setpgid(0, 0);
        signal(SIGTERM, SIG_DFL); signal(SIGINT, SIG_DFL); signal(SIGHUP, SIG_DFL);
        if (output >= 0) {
            if (dup2(output, STDOUT_FILENO) < 0 || dup2(output, STDERR_FILENO) < 0) _exit(71);
            if (output > STDERR_FILENO) close(output);
        }
        execv(args[0], args);
        perror("DroidBridge supervisor exec"); _exit(127);
    }
    if (pid > 0) setpgid(pid, pid);
    return pid;
}
static pid_t launch(char *const args[]) { return launch_output(args, -1); }
static int reap(pid_t child, int *status, double seconds) {
    double deadline = monotonic_seconds() + seconds;
    do {
        pid_t result = waitpid(child, status, WNOHANG);
        if (result == child || (result < 0 && errno == ECHILD)) return 1;
        if (result < 0 && errno != EINTR) return 1;
        pause_tick();
    } while (monotonic_seconds() < deadline);
    return 0;
}
static void terminate_child(pid_t child, int *status) {
    kill(-child, SIGTERM);
    if (!reap(child, status, 2.0)) {
        kill(-child, SIGKILL);
        while (waitpid(child, status, 0) < 0 && errno == EINTR) {}
    }
}
static void cleanup_command(char *const args[]) {
    /* The GUI and this crash-independent owner may finish the same cleanup.
     * Stage diagnostics so an already-absent exact listener is a successful
     * idempotent outcome, rather than an alarming (and misleading) ADB error.
     * Every other diagnostic remains visible. */
    FILE *capture = tmpfile();
    pid_t child = launch_output(args, capture ? fileno(capture) : -1); int status = -1;
    if (child > 0 && !reap(child, &status, 5.0)) terminate_child(child, &status);
    char output[16385] = {0}; size_t length = 0;
    if (capture) {
        rewind(capture); length = fread(output, 1, sizeof(output)-1, capture);
        fclose(capture);
    }
    int failed = child < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0;
    int absent = 0;
    if (failed && child > 0 && WIFEXITED(status) && !strcmp(args[3], "forward") && args[4] && !strcmp(args[4], "--remove") && args[5]) {
        char expected[512];
        snprintf(expected, sizeof(expected), "adb: error: listener '%s' not found", args[5]);
        while (length && (output[length-1] == '\n' || output[length-1] == '\r')) output[--length] = '\0';
        absent = !strcmp(output, expected);
    }
    if (absent) {
        fprintf(stderr, "{\"event\":\"supervisor_cleanup_already_complete\",\"operation\":\"forward\"}\n");
        return;
    }
    if (length) fprintf(stderr, "%s%s", output, output[length-1] == '\n' ? "" : "\n");
    if (failed)
        fprintf(stderr, "{\"event\":\"supervisor_cleanup_failed\",\"operation\":\"%s\"}\n", args[3]);
}
int main(int argc, char **argv) {
    pid_t parent = 0; char *adb = NULL, *serial = NULL, *forward = NULL, *remote = NULL;
    int command = 0;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--")) { command = i + 1; break; }
        if (i + 1 >= argc) return 64;
        char *option = argv[i], *value = argv[++i];
        if (!strcmp(option, "--parent")) {
            char *end; long parsed = strtol(value, &end, 10);
            if (*end || parsed <= 1 || parsed > 2147483647) return 64;
            parent = (pid_t)parsed;
        } else if (!strcmp(option, "--adb")) adb = value;
        else if (!strcmp(option, "--serial")) serial = value;
        else if (!strcmp(option, "--forward")) forward = value;
        else if (!strcmp(option, "--remote")) remote = value;
        else return 64;
    }
    if (!parent || !command || command >= argc || argv[command][0] != '/') return 64;
    if ((forward || remote) && (!adb || !serial || adb[0] != '/')) return 64;
    struct sigaction action; memset(&action, 0, sizeof(action));
    action.sa_handler = request_stop; sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, NULL); sigaction(SIGINT, &action, NULL); sigaction(SIGHUP, &action, NULL);
    /* Refuse to launch after the original GUI has already exited. */
    if (getppid() != parent) {
        if (forward) {
            char *args[] = {adb, "-s", serial, "forward", "--remove", forward, NULL};
            cleanup_command(args);
        }
        if (remote) {
            char *args[] = {adb, "-s", serial, "shell", "rm", "-f", remote, NULL};
            cleanup_command(args);
        }
        fprintf(stderr, "{\"event\":\"supervisor_stopped\",\"reason\":\"parent_missing_before_launch\",\"exit_status\":null,\"signal\":null}\n");
        return 75;
    }
    pid_t child = launch(&argv[command]);
    if (child < 0) { perror("DroidBridge supervisor fork"); return 71; }
    fprintf(stderr, "{\"event\":\"supervisor_started\",\"parent\":%d,\"child\":%d}\n", parent, child);
    int status = -1;
    const char *reason = "child_exit";
    for (;;) {
        pid_t result = waitpid(child, &status, WNOHANG);
        if (result == child || (result < 0 && errno == ECHILD)) break;
        if (result < 0 && errno != EINTR) { reason = "wait_error"; stopping = 1; }
        if (stopping || getppid() != parent) {
            if (strcmp(reason, "wait_error")) reason = stopping ? "stop_signal" : "parent_exit";
            terminate_child(child, &status); break;
        }
        pause_tick();
    }
    if (forward) {
        char *args[] = {adb, "-s", serial, "forward", "--remove", forward, NULL};
        cleanup_command(args);
    }
    if (remote) {
        char *args[] = {adb, "-s", serial, "shell", "rm", "-f", remote, NULL};
        cleanup_command(args);
    }
    char exit_value[16] = "null", signal_value[16] = "null", request_value[16] = "null";
    if (WIFEXITED(status)) snprintf(exit_value, sizeof(exit_value), "%d", WEXITSTATUS(status));
    if (WIFSIGNALED(status)) snprintf(signal_value, sizeof(signal_value), "%d", WTERMSIG(status));
    if (stop_signal) snprintf(request_value, sizeof(request_value), "%d", (int)stop_signal);
    fprintf(stderr, "{\"event\":\"supervisor_stopped\",\"reason\":\"%s\",\"exit_status\":%s,\"signal\":%s,\"requested_signal\":%s}\n", reason, exit_value, signal_value, request_value);
    return WIFEXITED(status) ? WEXITSTATUS(status) : (WIFSIGNALED(status) ? 128 + WTERMSIG(status) : 1);
}
