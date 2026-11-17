#ifndef MC_LINUX_GLOBAL_SHORTCUTS_H
#define MC_LINUX_GLOBAL_SHORTCUTS_H
#include <gio/gio.h>
typedef struct _GdkDisplay GdkDisplay;

/* Key/modifier values use the existing MoonBit shortcut_validate protocol. */
typedef struct { int key; int mods; } MCShortcutBinding;
/* Three binding slots are supplied by the host. IDs/descriptions are copied;
 * this adapter has no knowledge of the actions assigned to the slots. */
typedef struct { const char *id; const char *description; } MCShortcutDescriptor;
typedef void (*MCShortcutAction)(unsigned index, gpointer data);
/* Called only after native registration succeeds, while previous bindings are
 * still retained. Return FALSE when persistence fails to roll back registration. */
typedef gboolean (*MCShortcutCommit)(const MCShortcutBinding bindings[3],
    const char *const labels[3], gpointer data);
typedef void (*MCShortcutFinished)(gboolean success, const char *message, gpointer data);
/* labels are borrowed; Wayland labels describe the compositor's actual choices. */
typedef void (*MCShortcutState)(gboolean active, const char *message,
    const char *const labels[3], gpointer data);
typedef struct MCGlobalShortcuts MCGlobalShortcuts;

MCGlobalShortcuts *mc_global_shortcuts_new(GdkDisplay *display, const MCShortcutDescriptor descriptors[3], MCShortcutAction action,
    MCShortcutState state, gpointer data);
gboolean mc_global_shortcuts_is_portal(MCGlobalShortcuts *self);
gboolean mc_global_shortcuts_busy(MCGlobalShortcuts *self);
void mc_global_shortcuts_replace(MCGlobalShortcuts *self, const MCShortcutBinding bindings[3],
    const char *parent_window, MCShortcutCommit commit, MCShortcutFinished finished, gpointer data);
/* Releases this owner's grabs/sessions only. A pending transaction's Finished
 * callback is completed once on cancellation; no later callback targets the host. */
void mc_global_shortcuts_close(MCGlobalShortcuts *self);

/* Real Xvfb/XTest fixture; creates an independent manager, never captures media. */
gboolean mc_global_shortcuts_x11_smoke(void);
#endif
