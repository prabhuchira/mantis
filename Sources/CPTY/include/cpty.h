#ifndef CPTY_H
#define CPTY_H

#include <sys/types.h>

/// Fork a child attached to a new pseudo-terminal and exec `path`.
/// Everything the child needs is prepared by the caller *before* fork so the
/// child only performs async-signal-safe calls (chdir, signal, execve).
/// Returns the child pid (and writes the master fd to *out_master), or -1.
pid_t cpty_spawn(const char *path,
                 char *const argv[],
                 char *const envp[],
                 const char *cwd,
                 unsigned short rows,
                 unsigned short cols,
                 int *out_master);

/// TIOCSWINSZ wrapper (ioctl is variadic and not callable from Swift).
int cpty_set_size(int fd, unsigned short rows, unsigned short cols,
                  unsigned short xpixel, unsigned short ypixel);

/// Returns the foreground process group's leader pid for the tty, or -1.
pid_t cpty_foreground_pid(int fd);

/// Current working directory of `pid` (via proc_pidinfo). Returns 0 on success.
int cpty_process_cwd(pid_t pid, char *buf, int len);

#endif
