#ifndef MC_LINUX_PORTAL_SHORTCUTS_H
#define MC_LINUX_PORTAL_SHORTCUTS_H
#include "global_shortcuts.h"
typedef struct MCPortalShortcuts MCPortalShortcuts;
/* Copies all three host-provided descriptors. The caller supplies a session-bus
 * connection. Construction never asks for permission. Use on the main context. */
MCPortalShortcuts *mc_portal_shortcuts_new(GDBusConnection *connection,
    const MCShortcutDescriptor descriptors[3],
    MCShortcutAction action, MCShortcutState state, gpointer data);
void mc_portal_shortcuts_replace(MCPortalShortcuts *self, const MCShortcutBinding bindings[3],
    const char *parent_window, MCShortcutCommit commit, MCShortcutFinished finished, gpointer data);
gboolean mc_portal_shortcuts_busy(MCPortalShortcuts *self);
/* Releases the owning reference; asynchronous calls retain private cleanup state. */
void mc_portal_shortcuts_close(MCPortalShortcuts *self);
#endif
