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
static void request_stop(int signo) { (void)signo; stopping = 1; }
static void pause_tick(void) { struct timespec delay = {0, 50000000}; nanosleep(&delay, NULL); }
static double monotonic_seconds(void) {
    struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
    return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
}
static pid_t launch(char *const args[]) {
    pid_t pid = fork();
    if (pid == 0) {
        setpgid(0, 0);
        signal(SIGTERM, SIG_DFL); signal(SIGINT, SIG_DFL); signal(SIGHUP, SIG_DFL);
        execv(args[0], args);
        perror("DroidBridge supervisor exec"); _exit(127);
    }
    if (pid > 0) setpgid(pid, pid);
    return pid;
}
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
    pid_t child = launch(args); int status = 0;
    if (child > 0 && !reap(child, &status, 5.0)) terminate_child(child, &status);
    if (child < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0)
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
        return 75;
    }
    pid_t child = launch(&argv[command]);
    if (child < 0) { perror("DroidBridge supervisor fork"); return 71; }
    fprintf(stderr, "{\"event\":\"supervisor_started\",\"parent\":%d,\"child\":%d}\n", parent, child);
    int status = 0;
    for (;;) {
        pid_t result = waitpid(child, &status, WNOHANG);
        if (result == child || (result < 0 && errno == ECHILD)) break;
        if (result < 0 && errno != EINTR) { stopping = 1; }
        if (stopping || getppid() != parent) { terminate_child(child, &status); break; }
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
    fprintf(stderr, "{\"event\":\"supervisor_stopped\"}\n");
    return WIFEXITED(status) ? WEXITSTATUS(status) : (WIFSIGNALED(status) ? 128 + WTERMSIG(status) : 1);
}
