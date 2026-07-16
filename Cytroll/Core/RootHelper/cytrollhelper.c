#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

/*
 * cytrollhelper — TrollStore root execution proxy (Sileo/Filza/Dopamine pattern)
 *
 * Security (rootless):
 *   - Allowlisted executables only
 *   - Blocks signed system volume (SSV) paths
 *   - Jailbreak state confined to /var/jb
 */

static int path_has_prefix(const char *path, const char *prefix) {
    size_t plen = strlen(prefix);
    if (strncmp(path, prefix, plen) != 0) return 0;
    if (path[plen] == '\0' || path[plen] == '/') return 1;
    return 0;
}

static int is_blocked_system_path(const char *path) {
    static const char *blocked[] = {
        "/System",
        "/private/preboot",
        NULL
    };

    for (int i = 0; blocked[i]; i++) {
        if (path_has_prefix(path, blocked[i])) return 1;
    }
    return 0;
}

static int contains_path_traversal(const char *path) {
    if (strstr(path, "/../") != NULL) return 1;
    size_t len = strlen(path);
    if (len >= 3 && strcmp(path + len - 3, "/..") == 0) return 1;
    return 0;
}

/*
 * Bundled tools (tar/zstd/ldid/cytrollhelper itself) live at
 * <AppBundle>/Binaries/<tool>. Only trust this when the bundle sits inside
 * the *installed, read-only* app container (Bundle/Application) — never
 * the Data container, which is writable at runtime and could be used to
 * smuggle in a malicious "fake.app/Binaries/evil" path.
 */
static int is_bundled_binary_path(const char *path) {
    if (contains_path_traversal(path)) return 0;

    static const char *bundle_roots[] = {
        "/private/var/containers/Bundle/Application/",
        "/var/containers/Bundle/Application/",
        NULL
    };

    for (int i = 0; bundle_roots[i]; i++) {
        if (path_has_prefix(path, bundle_roots[i]) && strstr(path, ".app/Binaries/") != NULL) {
            return 1;
        }
    }
    return 0;
}

/*
 * Per-app tweak injection targets (AppInjectionManager) live at
 * /private/var/containers/Bundle/Application/<UUID>/<Name>.app/...
 * This is intentionally broader than is_bundled_binary_path() above (which
 * only ever covers OUR OWN read-only Binaries/ folder as the *executable*
 * to run): here we allowlist *arguments* so cp/insert_dylib/ldid/chmod can
 * operate on files strictly inside a third-party app's .app bundle
 * (main executable, Frameworks/) for injection/backup/restore.
 *
 * Still structurally confined to real Bundle/Application paths that
 * contain an actual ".app/" component — a bare
 * "/private/var/containers/Bundle/Application/evil" with no ".app/" is
 * still rejected. Apple's own system apps and SpringBoard never live
 * under this path (they ship on the sealed, read-only system volume), so
 * they are excluded by construction, not by an extra name check.
 */
static int is_third_party_app_bundle_path(const char *path) {
    if (contains_path_traversal(path)) return 0;

    static const char *bundle_roots[] = {
        "/private/var/containers/Bundle/Application/",
        "/var/containers/Bundle/Application/",
        NULL
    };

    for (int i = 0; bundle_roots[i]; i++) {
        if (path_has_prefix(path, bundle_roots[i]) && strstr(path, ".app/") != NULL) {
            return 1;
        }
    }
    return 0;
}

static int is_allowed_executable(const char *path) {
    if (!path || path[0] != '/') return 0;
    if (is_blocked_system_path(path)) return 0;
    if (contains_path_traversal(path)) return 0;

    static const char *allowed_prefixes[] = {
        "/var/jb",
        "/private/var/jb",
        "/bin/",
        "/usr/bin/",
        NULL
    };

    for (int i = 0; allowed_prefixes[i]; i++) {
        if (path_has_prefix(path, allowed_prefixes[i]) ||
            strcmp(path, allowed_prefixes[i]) == 0) {
            return 1;
        }
    }

    return is_bundled_binary_path(path);
}

static int argument_targets_system(const char *arg) {
    if (!arg || arg[0] != '/') return 0;
    if (is_blocked_system_path(arg)) return 1;
    if (contains_path_traversal(arg)) return 1;

    /* Procursus bootstrap extracts var/jb/ tree via tar -C / */
    if (strcmp(arg, "/") == 0) return 0;

    /* Per-app tweak injection: allow cp/insert_dylib/ldid/chmod to touch
     * paths strictly inside a third-party app's .app bundle. See
     * is_third_party_app_bundle_path() for the exact structural rule. */
    if (is_third_party_app_bundle_path(arg)) return 0;

    /* Block /var/* outside /var/jb */
    if (path_has_prefix(arg, "/var/") && !path_has_prefix(arg, "/var/jb")) return 1;
    if (path_has_prefix(arg, "/private/var/") &&
        !path_has_prefix(arg, "/private/var/jb") &&
        !path_has_prefix(arg, "/private/var/mobile") &&
        !path_has_prefix(arg, "/private/var/tmp")) {
        return 1;
    }

    return 0;
}

static int validate_arguments(char *const args[]) {
    for (int i = 0; args[i] != NULL; i++) {
        if (argument_targets_system(args[i])) {
            fprintf(stderr, "cytrollhelper: blocked unsafe path: %s\n", args[i]);
            return 0;
        }
    }
    return 1;
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <executable> [args...]\n", argv[0]);
        return 1;
    }

    const char *target = argv[1];

    if (!is_allowed_executable(target)) {
        fprintf(stderr, "cytrollhelper: executable not allowlisted: %s\n", target);
        return 1;
    }

    if (!validate_arguments(&argv[1])) {
        return 1;
    }

    /* Drop to group 0 before uid 0 (standard privilege-elevation order);
     * this binary must be installed setuid-root (owner root, mode 4755)
     * for these calls to actually succeed. */
    if (setgid(0) != 0) {
        perror("cytrollhelper: setgid failed");
        return 1;
    }
    if (setuid(0) != 0) {
        perror("cytrollhelper: setuid failed");
        return 1;
    }

    if (getuid() != 0 || getgid() != 0) {
        fprintf(stderr, "cytrollhelper: failed to obtain root privileges.\n");
        return 1;
    }

    execv(target, &argv[1]);
    perror("cytrollhelper: execv failed");
    return 1;
}
