#include "runtime.h"
#include <glib.h>
#include <gst/gst.h>
#include <string.h>

static bool fail(char *error, size_t capacity, const char *message) {
    if (error && capacity) g_strlcpy(error, message, capacity);
    return false;
}

static bool variable(const char *name, const char *value, char *error, size_t capacity) {
    return g_setenv(name, value, TRUE) || fail(error, capacity, "Cannot configure the private media runtime");
}

bool mc_linux_media_runtime_init(char *error, size_t capacity) {
    if (error && capacity) error[0] = 0;
    guint major, minor, micro, nano;
    gst_version(&major, &minor, &micro, &nano);
    if (major != GST_VERSION_MAJOR || minor != GST_VERSION_MINOR ||
        micro != GST_VERSION_MICRO || nano != GST_VERSION_NANO)
        return fail(error, capacity, "Loaded media libraries do not match this application build");

    gchar *executable = g_file_read_link("/proc/self/exe", NULL);
    if (!executable) return fail(error, capacity, "Cannot locate the application executable");
    gchar *directory = g_path_get_dirname(executable);
    gchar *plugins = g_build_filename(directory, "runtime", "plugins", NULL);
    gchar *scanner = g_build_filename(directory, "runtime", "bin", "gst-plugin-scanner", NULL);
    g_free(executable); g_free(directory);
    bool valid = g_file_test(plugins, G_FILE_TEST_IS_DIR) &&
        g_file_test(scanner, G_FILE_TEST_IS_REGULAR) && g_file_test(scanner, G_FILE_TEST_IS_EXECUTABLE);
    if (!valid) {
        g_free(plugins); g_free(scanner);
        return fail(error, capacity, "The media runtime is missing. Extract the complete application download");
    }

    /* A developer SDK or stale registry must not change the bundled plugins.
     * Keep desktop/GIO configuration: GTK uses the system GLib on Linux. */
    gchar **names = g_listenv();
    for (gchar **name = names; *name; name++)
        if (g_str_has_prefix(*name, "GST_") || g_str_has_prefix(*name, "GSTREAMER_")) g_unsetenv(*name);
    g_strfreev(names);
    g_unsetenv("LD_LIBRARY_PATH");
    bool configured = variable("GST_PLUGIN_SYSTEM_PATH_1_0", plugins, error, capacity) &&
        variable("GST_PLUGIN_SYSTEM_PATH", plugins, error, capacity) &&
        variable("GST_PLUGIN_PATH_1_0", "", error, capacity) &&
        variable("GST_PLUGIN_PATH", "", error, capacity) &&
        variable("GST_PLUGIN_SCANNER_1_0", scanner, error, capacity) &&
        variable("GST_PLUGIN_SCANNER", scanner, error, capacity);
    g_free(plugins); g_free(scanner);
    if (!configured) return false;

    const char *override = g_getenv("MOOJICUT_MEDIA_CACHE_DIR");
    gchar *cache = override && *override ? g_strdup(override) :
        g_build_filename(g_get_user_cache_dir(), "moojicut", "media", NULL);
    if (!g_path_is_absolute(cache) || g_mkdir_with_parents(cache, 0700) != 0 ||
        !g_file_test(cache, G_FILE_TEST_IS_DIR)) {
        g_free(cache);
        return fail(error, capacity, "Cannot create the media cache directory at an absolute path");
    }
    gchar *registry = g_build_filename(cache, "registry-x64.bin", NULL); g_free(cache);
    configured = variable("GST_REGISTRY_1_0", registry, error, capacity) &&
        variable("GST_REGISTRY", registry, error, capacity);
    g_free(registry);
    return configured;
}
