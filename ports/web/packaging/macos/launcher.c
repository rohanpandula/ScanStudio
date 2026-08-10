#include <mach-o/dyld.h>

#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int parent_directory(char *path) {
    char *separator = strrchr(path, '/');
    if (separator == NULL || separator == path) {
        return -1;
    }
    *separator = '\0';
    return 0;
}

static int regular_executable(const char *path) {
    struct stat info;
    return stat(path, &info) == 0 && S_ISREG(info.st_mode)
        && access(path, X_OK) == 0;
}

int main(int argc, char **argv) {
    (void)argv;
    if (argc != 1) {
        fprintf(stderr, "ScanStudio Web Runtime accepts configuration only through its documented environment.\n");
        return 64;
    }

    const char *configured_engine = getenv("SCANSTUDIO_ENGINE_PATH");
    if (configured_engine == NULL || configured_engine[0] != '/') {
        fprintf(stderr, "SCANSTUDIO_ENGINE_PATH must be an absolute path to the installed ScanStudio engine.\n");
        return 64;
    }
    char engine_path[PATH_MAX];
    if (realpath(configured_engine, engine_path) == NULL
        || !regular_executable(engine_path)) {
        fprintf(stderr, "SCANSTUDIO_ENGINE_PATH is not a resolvable regular executable.\n");
        return 66;
    }

    uint32_t executable_size = PATH_MAX;
    char executable_buffer[PATH_MAX];
    if (_NSGetExecutablePath(executable_buffer, &executable_size) != 0) {
        fprintf(stderr, "Could not resolve the web runtime executable path.\n");
        return 70;
    }
    char executable_path[PATH_MAX];
    if (realpath(executable_buffer, executable_path) == NULL) {
        fprintf(stderr, "Could not canonicalize the web runtime executable path.\n");
        return 70;
    }

    char contents_path[PATH_MAX];
    if (strlcpy(contents_path, executable_path, sizeof(contents_path))
            >= sizeof(contents_path)
        || parent_directory(contents_path) != 0
        || parent_directory(contents_path) != 0) {
        fprintf(stderr, "The web runtime bundle layout is invalid.\n");
        return 70;
    }

    char python_path[PATH_MAX];
    char static_path[PATH_MAX];
    if (snprintf(
            python_path,
            sizeof(python_path),
            "%s/Resources/Python/bin/python3.13",
            contents_path
        ) >= (int)sizeof(python_path)
        || snprintf(
            static_path,
            sizeof(static_path),
            "%s/Resources/WebFrontend",
            contents_path
        ) >= (int)sizeof(static_path)) {
        fprintf(stderr, "The web runtime bundle path is too long.\n");
        return 70;
    }
    if (!regular_executable(python_path)) {
        fprintf(stderr, "The bundled Python runtime is missing or not executable.\n");
        return 66;
    }
    struct stat static_info;
    if (stat(static_path, &static_info) != 0 || !S_ISDIR(static_info.st_mode)) {
        fprintf(stderr, "The bundled web frontend is missing.\n");
        return 66;
    }

    /* Defense in depth: the Python gateway repeats this scrub before it
       starts the host engine, but the signed launcher never forwards either
       hardware-enabling variable into the gateway process in the first place. */
    unsetenv("SCANSTUDIO_BRIDGE_CMD");
    unsetenv("SCANSTUDIO_HW_MOTION");
    if (setenv("SCANSTUDIO_ENGINE_PATH", engine_path, 1) != 0
        || setenv("SCANSTUDIO_WEB_STATIC_DIR", static_path, 1) != 0
        || setenv("PYTHONDONTWRITEBYTECODE", "1", 1) != 0
        || setenv("PYTHONNOUSERSITE", "1", 1) != 0) {
        fprintf(stderr, "Could not prepare the web runtime environment: %s\n", strerror(errno));
        return 70;
    }

    execl(
        python_path,
        python_path,
        "-I",
        "-m",
        "scanstudio_web.cli",
        (char *)NULL
    );
    fprintf(stderr, "Could not start the bundled Python gateway: %s\n", strerror(errno));
    return 70;
}
