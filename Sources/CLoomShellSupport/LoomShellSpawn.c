#include "CLoomShellSupport.h"

#include <signal.h>
#include <stddef.h>
#include <unistd.h>
#include <util.h>

static void loom_shell_reset_signals(void) {
    static const int signals_to_reset[] = {
        SIGHUP,
        SIGINT,
        SIGQUIT,
        SIGPIPE,
        SIGALRM,
        SIGTERM,
        SIGCHLD,
        SIGTSTP,
        SIGTTIN,
        SIGTTOU,
    };

    struct sigaction action = {0};
    action.sa_handler = SIG_DFL;
    sigemptyset(&action.sa_mask);

    for (size_t index = 0; index < sizeof(signals_to_reset) / sizeof(signals_to_reset[0]); index += 1) {
        (void)sigaction(signals_to_reset[index], &action, NULL);
    }
}

static void loom_shell_reset_signal_mask(void) {
    sigset_t empty_mask;
    sigemptyset(&empty_mask);
    (void)sigprocmask(SIG_SETMASK, &empty_mask, NULL);
}

__attribute__((noreturn))
static void loom_shell_child_fail(const char *message, size_t length) {
    while (length > 0) {
        ssize_t written = write(STDERR_FILENO, message, length);
        if (written <= 0) {
            break;
        }
        message += written;
        length -= (size_t)written;
    }
    _exit(127);
}

pid_t loom_shell_forkpty_spawn(
    int *master_fd,
    const char *path,
    char *const argv[],
    char *const envp[],
    const char *working_directory,
    const struct winsize *window_size
) {
    pid_t pid = forkpty(master_fd, NULL, NULL, (struct winsize *)window_size);
    if (pid != 0) {
        return pid;
    }

    loom_shell_reset_signal_mask();
    loom_shell_reset_signals();

    if (working_directory != NULL && chdir(working_directory) != 0) {
        loom_shell_child_fail(
            "loom-shell: failed to change working directory\r\n",
            sizeof("loom-shell: failed to change working directory\r\n") - 1
        );
    }

    execve(path, argv, envp);
    loom_shell_child_fail(
        "loom-shell: failed to exec login shell\r\n",
        sizeof("loom-shell: failed to exec login shell\r\n") - 1
    );
}
