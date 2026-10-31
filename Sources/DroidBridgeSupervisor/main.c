#define _POSIX_C_SOURCE 200809L
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <util.h>
#include <fcntl.h>
#include <termios.h>
#include <libproc.h>
#include <sys/proc_info.h>

/* Independent lifetime owner. A crashed GUI cannot run its own cleanup handler.
 * No shell is used, every child lives in its own process group, and cleanup
 * targets only the exact endpoint supplied by the owning session. */
static volatile sig_atomic_t stopping = 0;
static volatile sig_atomic_t stop_signal = 0;
static volatile sig_atomic_t latch_failure = 0;
static void request_stop(int signo) { stop_signal = signo; stopping = 1; }
static void request_failure(int signo) { latch_failure = 1; request_stop(signo); }
static void pause_tick(void) { struct timespec delay = {0, 50000000}; nanosleep(&delay, NULL); }
static double monotonic_seconds(void) {
    struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
    return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
}
static pid_t launch_output(char *const args[], int output) {
    pid_t pid = fork();
    if (pid == 0) {
        setpgid(0, 0);
        signal(SIGTERM, SIG_DFL); signal(SIGINT, SIG_DFL); signal(SIGHUP, SIG_DFL); signal(SIGPIPE, SIG_DFL);
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
/* A leased local TCP port is not authority to remove a foreign replacement.
 * ADB has no compare-and-delete primitive; compare the exact serial/local/remote
 * identity immediately before the scoped remove, refusing uncertainty. */
static void cleanup_forward(char *adb,char *serial,char *local,char *remote) {
    if (remote) {
        FILE *capture=tmpfile();
        if (!capture) return;
        char *query[]={adb,"-s",serial,"forward","--list",NULL};
        int status=-1; pid_t child=launch_output(query,fileno(capture));
        if (child>0 && !reap(child,&status,5.0)) terminate_child(child,&status);
        rewind(capture); char text[65537]={0}; size_t length=fread(text,1,sizeof(text)-1,capture);
        int overflow=fgetc(capture)!=EOF; fclose(capture);
        if (child<0 || !WIFEXITED(status) || WEXITSTATUS(status)!=0 || overflow) {
            fprintf(stderr,"{\"event\":\"supervisor_cleanup_failed\",\"operation\":\"forward_identity\"}\n"); return;
        }
        int matches=0,foreign=0;
        char *save=NULL;
        for (char *line=strtok_r(text,"\n",&save);line;line=strtok_r(NULL,"\n",&save)) {
            char found_serial[257],found_local[128],found_remote[128],extra[2];
            if (sscanf(line,"%256s %127s %127s %1s",found_serial,found_local,found_remote,extra)!=3) continue;
            if (!strcmp(found_serial,serial) && !strcmp(found_local,local)) {
                if (!strcmp(found_remote,remote)) ++matches; else foreign=1;
            }
        }
        (void)length;
        if (foreign || matches>1) {fprintf(stderr,"{\"event\":\"supervisor_cleanup_identity_changed\",\"operation\":\"forward\"}\n");return;}
        if (!matches) {fprintf(stderr,"{\"event\":\"supervisor_cleanup_already_complete\",\"operation\":\"forward\"}\n");return;}
    }
    char *args[]={adb,"-s",serial,"forward","--remove",local,NULL};
    cleanup_command(args);
}
/* A PTY makes the unmodified client's stdout line buffered. Relay only
 * bounded diagnostic bytes; it is not an interactive shell/controlling TTY. */
static void relay_output(int fd) {
    if (fd < 0) return;
    char bytes[4096];
    for (int batch = 0; batch < 16; ++batch) {
        ssize_t count = read(fd, bytes, sizeof(bytes));
        if (count <= 0) return;
        ssize_t sent = 0;
        while (sent < count) {
            ssize_t written = write(STDOUT_FILENO, bytes + sent, (size_t)(count - sent));
            if (written < 0 && errno == EINTR) continue;
            if (written <= 0) return;
            sent += written;
        }
    }
}
static int uuid_token(const char *value) {
    if (!value || strlen(value)!=36) return 0;
    for (int i=0; i<36; ++i) {
        if (i==8 || i==13 || i==18 || i==23) {if(value[i]!='-') return 0;}
        else if(!((value[i]>='0' && value[i]<='9') || (value[i]>='a' && value[i]<='f') || (value[i]>='A' && value[i]<='F'))) return 0;
    }
    return 1;
}
static int hex_tag(const char *value) {
    if (!value || strlen(value) != 64) return 0;
    for (int i=0; i<64; ++i) if (!((value[i]>='0' && value[i]<='9') || (value[i]>='a' && value[i]<='f'))) return 0;
    return 1;
}
static int failure_matches(const char *path,const char *tag) {
    int fd=open(path,O_RDONLY|O_CLOEXEC|O_NOFOLLOW);
    if (fd<0) return 0;
    struct stat metadata; char bytes[160]={0};
    int valid=fstat(fd,&metadata)==0 && S_ISREG(metadata.st_mode) && metadata.st_uid==getuid() && metadata.st_size<160;
    ssize_t count=valid ? read(fd,bytes,sizeof(bytes)-1) : -1; close(fd);
    char expected[96]; snprintf(expected,sizeof(expected),"\"tag\":\"%s\"",tag);
    return count>0 && strstr(bytes,expected)!=NULL;
}
static void failure_receipt(const char *path,const char *tag) {
    char temporary[4096];
    if (snprintf(temporary,sizeof(temporary),"%s.XXXXXX",path) >= (int)sizeof(temporary)) return;
    int fd=mkstemp(temporary);
    if (fd<0) return;
    fchmod(fd,0600);
    dprintf(fd,"{\"tag\":\"%s\"}\n",tag);
    fsync(fd); close(fd);
    if (rename(temporary,path)!=0) unlink(temporary);
}
/* Mirrors Core's admission under one policy gate. Shared owners on the same
 * alias coexist; a different alias cannot pass until every cleanup owner exits.
 * The descriptor remains here, never in the Android client or its child group. */
static int alias_file(const char *path) {
    if (!path || path[0] != '/') return -1;
    int fd=open(path,O_CREAT|O_RDWR|O_CLOEXEC|O_NOFOLLOW,0600);
    struct stat metadata;
    if (fd<0) return -1;
    if (fstat(fd,&metadata)!=0 || !S_ISREG(metadata.st_mode) || metadata.st_uid!=getuid() || (metadata.st_mode&0777)!=0600) {close(fd);return -1;}
    return fd;
}
static int acquire_alias(const char *gate_path,const char *lock_path,const char *serial) {
    if (!serial || !serial[0] || strlen(serial)>255) return -1;
    for (const unsigned char *p=(const unsigned char *)serial;*p;++p)
        if (!( (*p>='a'&&*p<='z') || (*p>='A'&&*p<='Z') || (*p>='0'&&*p<='9') || strchr("._:-%[]",*p))) return -1;
    int gate=alias_file(gate_path); if (gate<0) return -1;
    while (flock(gate,LOCK_EX)!=0) {if(errno!=EINTR){close(gate);return -1;}}
    int fd=alias_file(lock_path);
    if (fd<0) {close(gate);return -1;}
    int accepted=0;
    if (flock(fd,LOCK_EX|LOCK_NB)==0) {
        size_t size=strlen(serial);
        accepted=ftruncate(fd,0)==0 && pwrite(fd,serial,size,0)==(ssize_t)size && flock(fd,LOCK_SH)==0;
    } else if ((errno==EWOULDBLOCK || errno==EAGAIN) && flock(fd,LOCK_SH|LOCK_NB)==0) {
        char bytes[256]; ssize_t count=pread(fd,bytes,sizeof(bytes),0);
        accepted=count==(ssize_t)strlen(serial) && !memcmp(bytes,serial,(size_t)count);
    }
    flock(gate,LOCK_UN);close(gate);
    if (!accepted) {close(fd);return -1;}
    return fd;
}
static int same_child(pid_t pid,const struct proc_bsdinfo *original) {
    struct proc_bsdinfo current;
    return original->pbi_pid==(uint32_t)pid && proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&current,sizeof(current))==sizeof(current)
        && current.pbi_start_tvsec==original->pbi_start_tvsec && current.pbi_start_tvusec==original->pbi_start_tvusec
        && current.pbi_uid==getuid() && getpgid(pid)==pid;
}
/* A tiny non-exec guard retains the inherited alias/port/owner descriptors.
 * It sees explicit completion only AFTER supervisor cleanup. Unexpected EOF
 * means a supervisor crash, and never grants a second alias over a live child. */
static pid_t crash_guard(pid_t child,int *completion,char *adb,char *serial,char *forward,char *forward_remote,char *remote,char *failure_file,char *failure_tag,int output_master) {
    int pipes[2]; if(pipe(pipes)!=0) return -1;
    if(fcntl(pipes[0],F_SETFD,FD_CLOEXEC)!=0 || fcntl(pipes[1],F_SETFD,FD_CLOEXEC)!=0) {close(pipes[0]);close(pipes[1]);return -1;}
    struct proc_bsdinfo original; memset(&original,0,sizeof(original));
    if(proc_pidinfo(child,PROC_PIDTBSDINFO,0,&original,sizeof(original))!=sizeof(original) || original.pbi_ppid!=(uint32_t)getpid()) memset(&original,0,sizeof(original));
    pid_t guard=fork();
    if(guard==0) {
        setpgid(0,0); close(pipes[1]); if(output_master>=0)close(output_master);
        char byte=0; ssize_t count;
        do {count=read(pipes[0],&byte,1);} while(count<0 && errno==EINTR);
        close(pipes[0]);
        if(count==1 && byte=='C') _exit(0);
        fprintf(stderr,"{\"event\":\"supervisor_crash_guard_cleanup\",\"child\":%d}\n",child);
        if(same_child(child,&original)) {
            kill(-child,SIGTERM); double deadline=monotonic_seconds()+2.0;
            while(same_child(child,&original) && monotonic_seconds()<deadline) pause_tick();
            if(same_child(child,&original)) kill(-child,SIGKILL);
        }
        if(forward) cleanup_forward(adb,serial,forward,forward_remote);
        if(remote) {char *args[]={(char *)adb,"-s",(char *)serial,"shell","rm","-f",(char *)remote,NULL};cleanup_command(args);}
        if(failure_file) failure_receipt(failure_file,failure_tag);
        _exit(0);
    }
    close(pipes[0]);
    if(guard<0){close(pipes[1]);return -1;}
    *completion=pipes[1]; return guard;
}
int main(int argc, char **argv) {
    pid_t parent = 0; char *adb = NULL, *serial = NULL, *forward = NULL, *remote = NULL, *forward_remote = NULL;
    char *owner_lock = NULL, *owner_token = NULL, *failure_file = NULL, *failure_tag = NULL;
    int owner_fd = -1, alias_fd = -1;
    char *alias_lock = NULL, *alias_gate = NULL, *alias_serial = NULL;
    int command = 0, terminal_output = 0;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--")) { command = i + 1; break; }
        if (i + 1 >= argc) return 64;
        char *option = argv[i], *value = argv[++i];
        if (!strcmp(option, "--parent")) {
            char *end; long parsed = strtol(value, &end, 10);
            if (*end || parsed <= 1 || parsed > 2147483647) return 64;
            parent = (pid_t)parsed;
        } else if (!strcmp(option, "--terminal-output")) {
            if (strcmp(value, "1")) return 64;
            terminal_output = 1;
        } else if (!strcmp(option, "--owner-lock")) owner_lock = value;
        else if (!strcmp(option, "--alias-lock")) alias_lock = value;
        else if (!strcmp(option, "--alias-gate")) alias_gate = value;
        else if (!strcmp(option, "--alias-serial")) alias_serial = value;
        else if (!strcmp(option, "--owner-token")) owner_token = value;
        else if (!strcmp(option, "--failure-file")) failure_file = value;
        else if (!strcmp(option, "--failure-tag")) failure_tag = value;
        else if (!strcmp(option, "--adb")) adb = value;
        else if (!strcmp(option, "--serial")) serial = value;
        else if (!strcmp(option, "--forward")) forward = value;
        else if (!strcmp(option, "--remote")) remote = value;
        else if (!strcmp(option, "--forward-remote")) forward_remote = value;
        else return 64;
    }
    if (!parent || !command || command >= argc || argv[command][0] != '/') return 64;
    if ((alias_lock || alias_gate || alias_serial) && (!alias_lock || !alias_gate || !alias_serial)) return 64;
    if (owner_token && (!owner_lock || !uuid_token(owner_token))) return 64;
    if ((failure_file || failure_tag) && (!owner_lock || !failure_file || failure_file[0] != '/' || !hex_tag(failure_tag))) return 64;
    if ((forward || remote) && (!adb || !serial || adb[0] != '/')) return 64;
    if (forward_remote && (!forward || strncmp(forward_remote,"localabstract:scrcpy_",21) || strlen(forward_remote)!=29)) return 64;
    if (forward_remote) {
        for (int i=21;i<29;++i) if (!((forward_remote[i]>='0' && forward_remote[i]<='9') || (forward_remote[i]>='a' && forward_remote[i]<='f'))) return 64;
        if (forward_remote[21]>'7') return 64;
    }
    struct sigaction action; memset(&action, 0, sizeof(action));
    action.sa_handler = request_stop; sigemptyset(&action.sa_mask);
    signal(SIGPIPE,SIG_IGN);
    sigaction(SIGTERM, &action, NULL); sigaction(SIGINT, &action, NULL); sigaction(SIGHUP, &action, NULL);
    if (failure_file) {struct sigaction failure_action=action;failure_action.sa_handler=request_failure;sigaction(SIGUSR1,&failure_action,NULL);}
    /* Refuse to launch after the original GUI has already exited. */
    if (getppid() != parent) {
        if (forward) {
            cleanup_forward(adb,serial,forward,forward_remote);
        }
        if (remote) {
            char *args[] = {adb, "-s", serial, "shell", "rm", "-f", remote, NULL};
            cleanup_command(args);
        }
        fprintf(stderr, "{\"event\":\"supervisor_stopped\",\"reason\":\"parent_missing_before_launch\",\"exit_status\":null,\"signal\":null}\n");
        return 75;
    }
    if (alias_lock) {
        alias_fd=acquire_alias(alias_gate,alias_lock,alias_serial);
        if (alias_fd<0) {fprintf(stderr,"{\"event\":\"supervisor_alias_busy\"}\n");return 78;}
        fprintf(stderr,"{\"event\":\"supervisor_alias_acquired\"}\n");
    }
    /* This descriptor belongs to the supervisor, not the GUI or client. It
     * stays locked until process-group teardown AND exact tunnel cleanup finish.
     * Stable inode: never unlink or atomically replace the lock file. */
    if (owner_lock) {
        if (owner_lock[0] != '/') return 64;
        owner_fd = open(owner_lock, O_CREAT|O_RDWR|O_CLOEXEC|O_NOFOLLOW, 0600);
        struct stat metadata;
        if (owner_fd < 0 || fstat(owner_fd,&metadata) != 0
                || !S_ISREG(metadata.st_mode) || metadata.st_uid != getuid()
                || (metadata.st_mode & 0777) != 0600) {
            fprintf(stderr, "{\"event\":\"supervisor_owner_invalid\"}\n");
            if (owner_fd >= 0) close(owner_fd);
            return 73;
        }
        if (flock(owner_fd,LOCK_EX|LOCK_NB) != 0) {
            int busy = errno == EWOULDBLOCK || errno == EAGAIN;
            close(owner_fd);
            fprintf(stderr, "{\"event\":\"supervisor_owner_%s\"}\n",busy ? "busy" : "error");
            return busy ? 76 : 73;
        }
        if (stopping || getppid() != parent) { close(owner_fd); return 75; }
        if (failure_file && failure_matches(failure_file,failure_tag)) {
            fprintf(stderr,"{\"event\":\"supervisor_failure_latched\"}\n");
            close(owner_fd); return 77;
        }
        if (owner_token && (ftruncate(owner_fd,0)!=0 || pwrite(owner_fd,owner_token,strlen(owner_token),0)!=(ssize_t)strlen(owner_token))) {close(owner_fd);return 73;}
        fprintf(stderr, "{\"event\":\"supervisor_owner_acquired\"}\n");
    }
    int output_master = -1, output_slave = -1;
    if (terminal_output) {
        if (openpty(&output_master, &output_slave, NULL, NULL, NULL) < 0) { perror("DroidBridge output terminal"); return 71; }
        struct termios settings;
        if (tcgetattr(output_slave, &settings) < 0) return 71;
        cfmakeraw(&settings);
        if (tcsetattr(output_slave, TCSANOW, &settings) < 0
                || fcntl(output_master, F_SETFD, FD_CLOEXEC) < 0
                || fcntl(output_slave, F_SETFD, FD_CLOEXEC) < 0
                || fcntl(output_master, F_SETFL, O_NONBLOCK) < 0) return 71;
    }
    if (stopping || getppid() != parent) { if (owner_fd >= 0) close(owner_fd); return 75; }
    pid_t child = launch_output(&argv[command], output_slave);
    if (output_slave >= 0) close(output_slave);
    if (child < 0) { if (output_master >= 0) close(output_master); perror("DroidBridge supervisor fork"); return 71; }
    int guard_completion=-1; pid_t guard_pid=-1;
    int status = -1;
    if(alias_fd>=0) {
        guard_pid=crash_guard(child,&guard_completion,adb,serial,forward,forward_remote,remote,failure_file,failure_tag,output_master);
        if(guard_pid<0) {fprintf(stderr,"{\"event\":\"supervisor_crash_guard_failed\"}\n");terminate_child(child,&status);stopping=1;}
    }
    fprintf(stderr, "{\"event\":\"supervisor_started\",\"parent\":%d,\"child\":%d}\n", parent, child);
    const char *reason = "child_exit";
    for (;;) {
        relay_output(output_master);
        pid_t result = waitpid(child, &status, WNOHANG);
        if (result == child || (result < 0 && errno == ECHILD)) break;
        if (result < 0 && errno != EINTR) { reason = "wait_error"; stopping = 1; }
        if (stopping || getppid() != parent) {
            if (strcmp(reason, "wait_error")) reason = stopping ? "stop_signal" : "parent_exit";
            terminate_child(child, &status); break;
        }
        pause_tick();
    }
    relay_output(output_master);
    if (output_master >= 0) close(output_master);
    if (forward) {
        cleanup_forward(adb,serial,forward,forward_remote);
    }
    if (remote) {
        char *args[] = {adb, "-s", serial, "shell", "rm", "-f", remote, NULL};
        cleanup_command(args);
    }
    if(guard_completion>=0) {
        (void)write(guard_completion,"C",1);close(guard_completion);
        int guard_status=0;
        if(!reap(guard_pid,&guard_status,1.0)){kill(guard_pid,SIGKILL);while(waitpid(guard_pid,&guard_status,0)<0&&errno==EINTR){}}
    }
    if (failure_file && (!strcmp(reason,"child_exit") || latch_failure)) failure_receipt(failure_file,failure_tag);
    char exit_value[16] = "null", signal_value[16] = "null", request_value[16] = "null";
    if (WIFEXITED(status)) snprintf(exit_value, sizeof(exit_value), "%d", WEXITSTATUS(status));
    if (WIFSIGNALED(status)) snprintf(signal_value, sizeof(signal_value), "%d", WTERMSIG(status));
    if (stop_signal) snprintf(request_value, sizeof(request_value), "%d", (int)stop_signal);
    fprintf(stderr, "{\"event\":\"supervisor_stopped\",\"reason\":\"%s\",\"exit_status\":%s,\"signal\":%s,\"requested_signal\":%s}\n", reason, exit_value, signal_value, request_value);
    if (owner_fd >= 0) close(owner_fd);
    if (alias_fd >= 0) close(alias_fd);
    return WIFEXITED(status) ? WEXITSTATUS(status) : (WIFSIGNALED(status) ? 128 + WTERMSIG(status) : 1);
}
