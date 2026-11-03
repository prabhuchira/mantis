#include "cpty.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>
#include <libproc.h>
#include <sys/proc_info.h>

pid_t cpty_spawn(const char *path, char *const argv[], char *const envp[],
                 const char *cwd, unsigned short rows, unsigned short cols,
                 int *out_master) {
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_row = rows;
    ws.ws_col = cols;

    int master = -1;
    // forkpty = openpty + fork + login_tty (setsid, TIOCSCTTY, dup2 0/1/2).
    // Ghostty does the same steps by hand in src/pty.zig (openpty/setsid/TIOCSCTTY).
    pid_t pid = forkpty(&master, NULL, NULL, &ws);
    if (pid < 0) return -1;

    if (pid == 0) {
        // Child: restore default signal dispositions the GUI may have changed.
        signal(SIGCHLD, SIG_DFL);
        signal(SIGPIPE, SIG_DFL);
        signal(SIGINT, SIG_DFL);
        signal(SIGQUIT, SIG_DFL);
        signal(SIGTERM, SIG_DFL);
        signal(SIGHUP, SIG_DFL);
        sigset_t set;
        sigemptyset(&set);
        sigprocmask(SIG_SETMASK, &set, NULL);
        if (cwd && cwd[0]) (void)chdir(cwd);
        execve(path, argv, envp);
        _exit(127);
    }

    // Parent: enable UTF-8 aware line editing (backspace over multibyte chars).
    struct termios t;
    if (tcgetattr(master, &t) == 0) {
#ifdef IUTF8
        t.c_iflag |= IUTF8;
#endif
        tcsetattr(master, TCSANOW, &t);
    }
    fcntl(master, F_SETFD, FD_CLOEXEC);
    *out_master = master;
    return pid;
}

int cpty_set_size(int fd, unsigned short rows, unsigned short cols,
                  unsigned short xpixel, unsigned short ypixel) {
    struct winsize ws;
    ws.ws_row = rows;
    ws.ws_col = cols;
    ws.ws_xpixel = xpixel;
    ws.ws_ypixel = ypixel;
    return ioctl(fd, TIOCSWINSZ, &ws);
}

pid_t cpty_foreground_pid(int fd) {
    return tcgetpgrp(fd);
}

int cpty_process_cwd(pid_t pid, char *buf, int len) {
    struct proc_vnodepathinfo vpi;
    int n = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, sizeof(vpi));
    if (n != (int)sizeof(vpi)) return -1;
    strlcpy(buf, vpi.pvi_cdir.vip_path, (size_t)len);
    return 0;
}
