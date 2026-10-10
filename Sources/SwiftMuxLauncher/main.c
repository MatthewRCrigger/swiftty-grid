// swmux-launcher: fresh-process terminal setup for one SwiftMux pane.
//
// The service posix_spawns this executable (without POSIX_SPAWN_SETSID) with
//   fd 3 = PTY slave, fd 4 = status pipe (write end), and every other
//   descriptor closed (POSIX_SPAWN_CLOEXEC_DEFAULT).
// argv: swmux-launcher <directory> <program> <argv0> [arguments...]
//
// It creates exactly one session with the slave as controlling terminal
// (login_tty), sets the directory and signal state, reports "S" and execs
// the program in place, so no launcher process remains. Failures report
// "E <stage> <errno>" and exit 127; the pipe's close-on-exec EOF alone is
// not treated as success by the service.
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <util.h>

extern char **environ;

static void report(const char *kind, const char *stage, int err) {
  char line[128];
  int n = snprintf(line, sizeof line, "%s %s %d\n", kind, stage, err);
  if (n > 0) {
    ssize_t ignored = write(4, line, (size_t)n);
    (void)ignored;
  }
}

static void fail(const char *stage, int err) {
  report("E", stage, err);
  _exit(127);
}

int main(int argc, char **argv) {
  if (argc < 4) fail("arguments", EINVAL);
  if (fcntl(4, F_SETFD, FD_CLOEXEC) != 0) fail("status-pipe", errno);
  if (!isatty(3)) fail("slave", errno ? errno : ENOTTY);

  // setsid, TIOCSCTTY on fd 3, dup2 to 0/1/2, close 3.
  if (login_tty(3) != 0) fail("login_tty", errno);
  pid_t self = getpid();
  if (getsid(0) != self) fail("session", EPERM);
  if (tcgetsid(0) != self) fail("controlling-tty", ENOTTY);
  if (tcgetpgrp(0) != getpgrp()) fail("foreground", EPERM);

  const char *directory = argv[1];
  if (directory[0] != '\0' && chdir(directory) != 0) {
    report("W", "chdir", errno);
    const char *home = getenv("HOME");
    if (home == NULL || chdir(home) != 0) {
      if (chdir("/") != 0) fail("chdir", errno);
    }
  }

  // Default dispositions and an empty mask for the shell.
  for (int sig = 1; sig < NSIG; sig++) {
    if (sig != SIGKILL && sig != SIGSTOP) signal(sig, SIG_DFL);
  }
  sigset_t none;
  sigemptyset(&none);
  sigprocmask(SIG_SETMASK, &none, NULL);

  const char *program = argv[2];
  char **child_argv = &argv[3];
  report("S", "exec", 0);
  execve(program, child_argv, environ);
  fail("exec", errno);
  return 127;
}
