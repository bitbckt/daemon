import core.stdc.errno;
import core.stdc.stdio : perror, SEEK_SET;

version (Posix) {
    import core.sys.posix.fcntl;
    import core.sys.posix.poll;
    import core.sys.posix.signal;
    import core.sys.posix.unistd;
    import core.sys.posix.sys.resource;
    import core.sys.posix.sys.stat;
    import core.sys.posix.sys.wait;
} else {
    static assert(0);
}

private void writeCode(int fd, int code) nothrow @nogc @trusted {
    write(fd, &code, code.sizeof);
}

private void writePID(int fd, pid_t pid) nothrow @nogc @trusted {
    write(fd, &pid, pid.sizeof);
}

private int readCode(int fd) nothrow @nogc @trusted {
    int code;
    read(fd, &code, code.sizeof);
    return code;
}

private pid_t readPID(int fd) nothrow @nogc @trusted {
    pid_t pid;
    read(fd, &pid, pid.sizeof);
    return pid;
}

private void waitPID(pid_t pid) nothrow @nogc @trusted {
    int status;
    waitpid(pid, &status, 0);
}

private pid_t doubleFork(int[2] pipefd, uid_t user, gid_t group) nothrow @nogc @safe {
    assert(user != 0);
    assert(group != 0);

    pid_t pid;

    pid = fork();
    switch (pid) {
    case -1: // error
        close(pipefd[0]);
        close(pipefd[1]);
        return -1;
    case 0: // first child
        close(pipefd[0]);

        if (setsid() == -1) {
            writeCode(pipefd[1], errno);
            close(pipefd[1]);
            return -1;
        }

        pid = fork();

        switch (pid) {
        case -1: // error
            writeCode(pipefd[1], errno);
            close(pipefd[1]);
            return -1;
        case 0: // second child (the daemon)

            // drop privileges
            if (setgid(group) == -1) {
                writeCode(pipefd[1], errno);
                close(pipefd[1]);
                return -1;
            }

            if (setuid(user) == -1) {
                writeCode(pipefd[1], errno);
                close(pipefd[1]);
                return -1;
            }

            // Paranoia: attempt to regain privileges
            if (setuid(0) != -1) {
                writeCode(pipefd[1], -1);
                close(pipefd[1]);
                return -1;
            }

            writeCode(pipefd[1], 0);

            pid = getpid();
            writePID(pipefd[1], pid);

            close(pipefd[1]);
            return 0;
        default: // second parent
            return -1;
        }

    default: // first parent

        // Wait for the child to exit.
        waitPID(pid);

        close(pipefd[1]);

        const int code = readCode(pipefd[0]);

        if (code == 0) {
            pid = readPID(pipefd[0]);
        }

        close(pipefd[0]);

        errno = code;

        if (code == 0) {
            return pid;
        } else {
            return -1;
        }
    }

    assert(0);
}

private int redirectDescriptors() nothrow @nogc {
    // Close standard FDs.
    close(STDIN_FILENO);
    close(STDOUT_FILENO);
    close(STDERR_FILENO);

    if (open("/dev/null", O_RDONLY) != 0) {
        return 1;
    }

    if (open("/dev/null", O_WRONLY) != 0) {
        return 1;
    }

    if (dup(STDOUT_FILENO) != STDERR_FILENO) {
        return 1;
    }

    return 0;
}

private pid_t daemonize(uid_t user, gid_t group) nothrow {
    import core.stdc.stdlib : malloc, free;

    rlimit rl;

    if (getrlimit(RLIMIT_NOFILE, &rl) != 0) {
        perror("getrlimit");
        return -1;
    }

    immutable maxDescriptors = cast(int) rl.rlim_cur;
    immutable maxToClose = maxDescriptors - 3;

    auto fds = cast(pollfd*) malloc(pollfd.sizeof * maxToClose);
    if (fds is null) {
        return -1;
    }

    foreach (i; 0 .. maxToClose) {
        fds[i].fd = i + 3;
        fds[i].events = 0;
        fds[i].revents = 0;
    }

    // Close all open files, except the std descriptors.
    if (poll(fds, maxToClose, 0) >= 0) {
        foreach (i; 0 .. maxToClose) {
            if (!(fds[i].revents & POLLNVAL)) {
                close(fds.fd);
            }
        }
    }

    free(fds);

    version (linux) {
        const int nsig = SIGRTMAX;
    }

    // Reset all signals to their defaults.
    for (int i = 0; i < nsig; i++) {
        signal(i, SIG_DFL);
    }

    // Reset errno.
    errno = 0;

    sigset_t sigset;

    // Block all signals.
    sigfillset(&sigset);
    if (sigprocmask(SIG_BLOCK, &sigset, null) != 0) {
        perror("sigprocmask");
        return -1;
    }

    int[2] pipefd;

    // Mint a pipe for comms.
    if (pipe(pipefd) != 0) {
        perror("pipe");
        return -1;
    }

    pid_t pid;

    // Double fork to daemonize.
    if ((pid = doubleFork(pipefd, user, group)) < 0) {
        return -1;
    }

    // Unblock all signals.
    sigfillset(&sigset);
    if (sigprocmask(SIG_UNBLOCK, &sigset, null) != 0) {
        perror("sigprocmask");
        return -1;
    }

    if (pid != 0) { // this is the original process
        return pid;
    }

    if (redirectDescriptors() != 0) {
        return -1;
    }

    // Change pwd to the root.
    if (chdir("/") != 0) {
        perror("chdir");
        return -1;
    }

    // Clear umask.
    umask(0);

    return pid;
}

private int checkFile(scope const char[] pidfile) nothrow {
    import std.string : toStringz;

    flock fl;

    int fd = open(pidfile.toStringz, O_RDWR);
    if (fd == -1) {
        if (errno == ENOENT) { // file does not exist
            errno = 0;
            return 0;
        }

        return 1;
    }

    scope (exit) {
        close(fd);
    }

    fl.l_type = F_WRLCK;
    fl.l_whence = SEEK_SET;
    fl.l_start = 0;
    fl.l_len = 0;
    fl.l_pid = getpid();

    if (fcntl(fd, F_SETLK, &fl) == -1) {
        // file is locked
        if (errno == EAGAIN || errno == EACCES) {
            return -1;
        }

        return 1;
    }

    fl.l_type = F_UNLCK;
    if (fcntl(fd, F_SETLK, &fl) == -1) {
        return 1;
    }

    return 0;
}

pid_t run(scope string pidfile, uid_t user, uid_t group,
        int function() nothrow fn, int* exit_code) nothrow {
    import core.stdc.string : strlen;
    import std.string : toStringz;

    const int status = checkFile(pidfile);

    if (status == -1) {
        // daemon already running
        errno = 0;
        return -2;
    } else if (status == 1) {
        // permissions error: cannot open or lock
        return -1;
    }

    pid_t pid = daemonize(user, group);

    if (pid == -1) {
        return -1;
    }

    if (pid != 0) { // this is the original process
        return pid;
    }

    auto filename = pidfile.toStringz;
    if (access(filename, F_OK) != -1) {
        unlink(filename);
        errno = 0;
    }

    mode_t mask = S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH; // 0644
    int fd = open(filename, O_RDWR | O_CREAT, mask);

    if (fd == -1) {
        return -1;
    }

    scope (exit) {
        close(fd);
        unlink(filename);
    }

    if (write(fd, filename, strlen(filename)) == -1) {
        return -1;
    }

    flock fl;

    fl.l_type = F_WRLCK;
    fl.l_whence = SEEK_SET;
    fl.l_start = 0;
    fl.l_len = 0;
    fl.l_pid = getpid();

    // Lock the PID file.
    if (fcntl(fd, F_SETLK, &fl) == -1) {
        return -1;
    }

    const int code = fn();
    if (exit_code != null) {
        *exit_code = code;
    }

    // Unlock the PID file.
    fl.l_type = F_UNLCK;
    fcntl(fd, F_SETLK, &fl);

    return pid;
}
