import dlogg.log;
import dlogg.strict;

version (Posix) {
    import core.sys.posix.pwd : passwd, getpwnam;
    import core.sys.posix.sys.types;
} else {
    static assert(0);
}

nothrow int serve() {
    // NB. Allows nothrow code to call throw code.
    scope (failure) {
        return 1;
    }

    auto log = new shared StrictLogger("/tmp/daemon.log");
    log.minOutputLevel = LoggingLevel.Debug;

    scope (exit) {
        log.finalize();
    }

    logInfo(log, "Success!");

    return 0;
}

int main() {
    import core.stdc.errno;
    import core.stdc.stdio : perror;
    import daemon;

    int exit_code;

    errno = 0;

    passwd* user = getpwnam("daemon");
    if (user == null) {
        perror("getpwnam");
        return -1;
    }

    pid_t pid = daemon.run("/var/run/daemon.pid", user.pw_uid, user.pw_gid, &serve, &exit_code);

    if (pid == -1) {
        return -1;
    }

    return exit_code;
}
