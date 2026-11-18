#ifndef MOOJICUT_DESKTOP_PLUGINS_H
#define MOOJICUT_DESKTOP_PLUGINS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "package_zip.h"

typedef struct MCDesktopPlugins MCDesktopPlugins;

/* UI adapter. Callbacks and the driver run on the application thread.
 * preflight must leave the active toolbar unchanged. publish takes ownership
 * of a new tool registry snapshot. discard releases a failed preflight.
 * Result and message strings are borrowed UTF-8 for the callback duration. */
typedef struct {
    void *context;
    bool (*preflight)(void *context, int32_t snapshot, const char *registry_json);
    void (*publish)(void *context, int32_t snapshot, const char *registry_json);
    void (*discard)(void *context);
    void (*message)(void *context, const char *text, bool error);
    void (*result)(void *context, int32_t capture, const char *tool_id, const char *title,
                   const char *text, bool document_changed);
    void (*import_complete)(void *context, bool success);
} MCDesktopPluginHooks;

/* Pure platform utilities, also called off the main thread. read_zip allocates
 * with malloc and reads at most MC_PLUGIN_ZIP_MAX_BYTES, rejecting larger
 * files. sha256 writes a NUL-terminated lower-case digest. */
typedef struct {
    bool (*read_zip)(const char *path, uint8_t **bytes, size_t *size, char error[256]);
    bool (*sha256)(const uint8_t *bytes, size_t size, char digest[65]);
    MCPluginZipInflate inflate;
} MCDesktopPluginPlatform;

/* root and worker are host-selected absolute UTF-8 paths. The root parent
 * is private and already provisioned. layout seeds a missing durable index.
 * Successful startup synchronously publishes the initial registry. */
MCDesktopPlugins *mc_desktop_plugins_open(const char *root, const char *worker,
    const char *layout, int32_t capabilities, const MCDesktopPluginHooks *hooks);
MCDesktopPlugins *mc_desktop_plugins_open_with_platform(const char *root, const char *worker,
    const char *layout, int32_t capabilities, const MCDesktopPluginHooks *hooks,
    const MCDesktopPluginPlatform *platform);

/* Import is asynchronous. Pump on the main thread while the app is running.
 * Configuration/removal execute a preflight and durable CAS before publication.
 * An empty before_id moves to the end of the tool's own group and slot. */
bool mc_desktop_plugins_import(MCDesktopPlugins *host, const char *zip_path);
bool mc_desktop_plugins_enabled(MCDesktopPlugins *host, const char *tool_id, bool enabled);
bool mc_desktop_plugins_move(MCDesktopPlugins *host, const char *tool_id, const char *before_id);
bool mc_desktop_plugins_uninstall(MCDesktopPlugins *host, const char *plugin_id);
bool mc_desktop_plugins_invoke(MCDesktopPlugins *host, int32_t capture,
    const char *tool_id, const char *payload);
void mc_desktop_plugins_close_capture(MCDesktopPlugins *host, int32_t capture);
const uint8_t *mc_desktop_plugins_icon(const MCDesktopPlugins *host, const char *plugin_id, size_t *size);
void mc_desktop_plugins_pump(MCDesktopPlugins *host);
bool mc_desktop_plugins_busy(const MCDesktopPlugins *host);
/* Starts cancellation. Keep the host and pumping until this returns true.
 * A successful close frees the host. A NULL host is already closed. */
bool mc_desktop_plugins_close(MCDesktopPlugins *host);

#endif
