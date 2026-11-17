#include "global_shortcuts.h"
#include "portal_shortcuts.h"
#include <gdk/gdkx.h>
#include <gdk/gdkwayland.h>
#include <glib-unix.h>
#include <X11/XKBlib.h>
#include <X11/keysym.h>
#include <dlfcn.h>
#include <string.h>

typedef struct { Window root; KeyCode code; unsigned mods; unsigned action; } Grab;
struct MCGlobalShortcuts {
  unsigned references;
  gboolean closed, portal_backend, connecting, active, replacing;
  MCShortcutAction action;
  MCShortcutState state;
  gpointer data;
  Display *xdisplay;
  GArray *grabs;
  MCShortcutBinding bindings[3];
  MCShortcutDescriptor descriptors[3];
  gboolean down[256], detectable_repeat;
  unsigned locks, source, queued_events;
  GCancellable *connect_cancel;
  MCPortalShortcuts *portal;
};
static MCGlobalShortcuts *retain(MCGlobalShortcuts *self) { self->references++; return self; }
static void release(gpointer data) {
  MCGlobalShortcuts *self = data;
  if (--self->references) return;
  if (self->xdisplay) XCloseDisplay(self->xdisplay);
  if (self->grabs) g_array_unref(self->grabs);
  g_clear_object(&self->connect_cancel);
  for (unsigned i = 0; i < 3; i++) {
    g_free((char *)self->descriptors[i].id); g_free((char *)self->descriptors[i].description);
  }
  g_free(self);
}
static void status(MCGlobalShortcuts *self, gboolean active, const char *message, const char *const labels[3]) {
  self->active = active;
  if (!self->closed && self->state) self->state(active, message, labels, self->data);
}
static unsigned xmods(int mods) {
  return ((mods & 1) ? ControlMask : 0) | ((mods & 2) ? Mod1Mask : 0) |
    ((mods & 4) ? ShiftMask : 0) | ((mods & 8) ? Mod4Mask : 0);
}
static KeySym keysym(int key) {
  if (key >= 256 && key <= 279) return XK_F1 + key - 256;
  return ((key >= 'A' && key <= 'Z') || (key >= '0' && key <= '9')) ? (KeySym)key : NoSymbol;
}
static unsigned lock_modifiers(Display *display) {
  unsigned masks = LockMask;
  XModifierKeymap *map = XGetModifierMapping(display);
  if (!map) return masks;
  for (int modifier = 0; modifier < 8; modifier++)
    for (int key = 0; key < map->max_keypermod; key++) {
      KeyCode code = map->modifiermap[modifier * map->max_keypermod + key];
      KeySym sym = code ? XkbKeycodeToKeysym(display, code, 0, 0) : NoSymbol;
      if (sym == XK_Num_Lock || sym == XK_Scroll_Lock || sym == XK_Caps_Lock || sym == XK_Shift_Lock)
        masks |= 1u << modifier;
    }
  XFreeModifiermap(map);
  return masks;
}
static gboolean equal_grab(Grab a, Grab b) { return a.root == b.root && a.code == b.code && a.mods == b.mods; }
static gboolean contains(GArray *grabs, Grab value) {
  for (guint i = 0; i < grabs->len; i++) if (equal_grab(g_array_index(grabs, Grab, i), value)) return TRUE;
  return FALSE;
}
static GArray *build_grabs(MCGlobalShortcuts *self, const MCShortcutBinding bindings[3], unsigned locks) {
  GArray *result = g_array_new(FALSE, FALSE, sizeof(Grab));
  for (unsigned action = 0; action < 3; action++) {
    if (bindings[action].mods < 0 || bindings[action].mods > 15 ||
        (!bindings[action].key && bindings[action].mods)) { g_array_unref(result); return NULL; }
    if (!bindings[action].key) continue;
    KeySym sym = keysym(bindings[action].key);
    KeyCode code = sym ? XKeysymToKeycode(self->xdisplay, sym) : 0;
    unsigned mods = xmods(bindings[action].mods);
    if (!code || (mods & locks)) { g_array_unref(result); return NULL; }
    for (int screen = 0; screen < ScreenCount(self->xdisplay); screen++) {
      unsigned subset = locks;
      for (;;) {
        Grab grab = {RootWindow(self->xdisplay, screen), code, mods | subset, action};
        if (contains(result, grab)) { g_array_unref(result); return NULL; }
        g_array_append_val(result, grab);
        if (!subset) break;
        subset = (subset - 1) & locks;
      }
    }
  }
  return result;
}
/* Xlib error handlers are process-global. Restrict this short, synchronous
 * trap to our separate connection and preserve GTK/other clients' handler. */
static Display *trapped_display;
static int trapped_error;
static int (*previous_error_handler)(Display *, XErrorEvent *);
static int grab_error(Display *display, XErrorEvent *error) {
  if (display == trapped_display) { trapped_error = error->error_code; return 0; }
  return previous_error_handler ? previous_error_handler(display, error) : 0;
}
static void ungrab_difference(MCGlobalShortcuts *self, GArray *from, GArray *keep) {
  for (guint i = 0; i < from->len; i++) {
    Grab grab = g_array_index(from, Grab, i);
    if (!keep || !contains(keep, grab)) XUngrabKey(self->xdisplay, grab.code, grab.mods, grab.root);
  }
  XSync(self->xdisplay, False);
}
static gboolean replace_x11(MCGlobalShortcuts *self, const MCShortcutBinding bindings[3],
    MCShortcutCommit commit, gpointer data, const char **message) {
  unsigned locks = lock_modifiers(self->xdisplay);
  GArray *next = build_grabs(self, bindings, locks);
  if (!next) { *message = "当前键盘映射不支持这个组合，请换一个。"; return FALSE; }
  XSync(self->xdisplay, False);
  trapped_display = self->xdisplay; trapped_error = 0;
  previous_error_handler = XSetErrorHandler(grab_error);
  for (guint i = 0; i < next->len; i++) {
    Grab grab = g_array_index(next, Grab, i);
    if (!contains(self->grabs, grab))
      XGrabKey(self->xdisplay, grab.code, grab.mods, grab.root, False, GrabModeAsync, GrabModeAsync);
  }
  XSync(self->xdisplay, False);
  XSetErrorHandler(previous_error_handler); trapped_display = NULL;
  gboolean success = trapped_error == 0;
  if (success && commit) success = commit(bindings, NULL, data);
  if (!success || self->closed) {
    ungrab_difference(self, next, self->grabs);
    *message = trapped_error ? "快捷键已被其他应用或功能占用；原快捷键保持不变。" : "设置未保存；原快捷键保持不变。";
    g_array_unref(next); return FALSE;
  }
  ungrab_difference(self, self->grabs, next);
  g_array_unref(self->grabs); self->grabs = next; self->locks = locks;
  memcpy(self->bindings, bindings, sizeof(self->bindings));
  /* Recording a shortcut may release a local keyboard grab while its final
   * key is still held. Do not turn that held key's repeat into an action. */
  char pressed[32]; XQueryKeymap(self->xdisplay, pressed);
  for (unsigned code = 0; code < 256; code++)
    self->down[code] = ((unsigned char)pressed[code / 8] & (1u << (code % 8))) != 0;
  *message = next->len ? "X11 全局快捷键已启用。" : "全局快捷键已清除。";
  return TRUE;
}
static gboolean x_events(gint fd, GIOCondition condition, gpointer data) {
  (void)fd;
  MCGlobalShortcuts *self = retain(data);
  if (condition & (G_IO_HUP | G_IO_ERR | G_IO_NVAL)) {
    self->source = 0;
    status(self, FALSE, "X11 输入连接已断开；全局快捷键不可用。", NULL);
    release(self); return G_SOURCE_REMOVE;
  }
  while (!self->closed && XPending(self->xdisplay)) {
    XEvent event; XNextEvent(self->xdisplay, &event);
    if (event.type == MappingNotify) {
      XRefreshKeyboardMapping(&event.xmapping);
      const char *message = NULL;
      if (!replace_x11(self, self->bindings, NULL, NULL, &message)) {
        ungrab_difference(self, self->grabs, NULL);
        g_array_set_size(self->grabs, 0);
        status(self, FALSE, "键盘映射已改变，快捷键重新注册失败；请在设置中重试。", NULL);
      }
      continue;
    }
    if (event.type != KeyPress && event.type != KeyRelease) continue;
    if (event.type == KeyRelease) {
      if (!self->detectable_repeat && XEventsQueued(self->xdisplay, QueuedAfterReading)) {
        XEvent next; XPeekEvent(self->xdisplay, &next);
        if (next.type == KeyPress && next.xkey.keycode == event.xkey.keycode && next.xkey.time == event.xkey.time) continue;
      }
      if (event.xkey.keycode < G_N_ELEMENTS(self->down)) self->down[event.xkey.keycode] = FALSE;
      continue;
    }
    unsigned mods = event.xkey.state & 0xffu;
    for (guint i = 0; i < self->grabs->len; i++) {
      Grab grab = g_array_index(self->grabs, Grab, i);
      if (grab.root == event.xkey.root && grab.code == event.xkey.keycode && grab.mods == mods) {
        if (!self->down[grab.code]) {
          self->down[grab.code] = TRUE;
          if (self->action) self->action(grab.action, self->data);
        }
        break;
      }
    }
  }
  gboolean closed = self->closed;
  release(self); return closed ? G_SOURCE_REMOVE : G_SOURCE_CONTINUE;
}
static gboolean drain_queued_events(gpointer data) {
  MCGlobalShortcuts *self = data;
  self->queued_events = 0;
  x_events(-1, 0, self);
  return G_SOURCE_REMOVE;
}
static void schedule_queued_events(MCGlobalShortcuts *self) {
  /* XSync/XQueryKeymap can move events from the socket into Xlib's own queue.
   * A readable-fd source alone would then wait until a later key arrives. */
  if (!self->closed && !self->queued_events && XPending(self->xdisplay))
    self->queued_events = g_idle_add_full(G_PRIORITY_DEFAULT, drain_queued_events, retain(self), release);
}
static void portal_action(unsigned index, gpointer data) {
  MCGlobalShortcuts *self = data;
  if (!self->closed && self->action) self->action(index, self->data);
}
static void portal_state(gboolean active, const char *message, const char *const labels[3], gpointer data) {
  status(data, active, message, labels);
}
static void bus_ready(GObject *source, GAsyncResult *result, gpointer data) {
  (void)source;
  MCGlobalShortcuts *self = data;
  GError *error = NULL; GDBusConnection *connection = g_bus_get_finish(result, &error);
  self->connecting = FALSE;
  if (!self->closed) {
    if (connection) self->portal = mc_portal_shortcuts_new(connection, self->descriptors, portal_action, portal_state, self);
    else status(self, FALSE, "无法连接桌面门户；可继续使用托盘操作。", NULL);
  }
  g_clear_object(&connection); g_clear_error(&error); release(self);
}
MCGlobalShortcuts *mc_global_shortcuts_new(GdkDisplay *display, const MCShortcutDescriptor descriptors[3], MCShortcutAction action, MCShortcutState state, gpointer data) {
  MCGlobalShortcuts *self = g_new0(MCGlobalShortcuts, 1);
  self->references = 1; self->action = action; self->state = state; self->data = data;
  for (unsigned i = 0; i < 3; i++) {
    self->descriptors[i].id = g_strdup(descriptors[i].id);
    self->descriptors[i].description = g_strdup(descriptors[i].description);
  }
  self->portal_backend = GDK_IS_WAYLAND_DISPLAY(display) || g_strcmp0(g_getenv("XDG_SESSION_TYPE"), "wayland") == 0;
  if (self->portal_backend) {
    self->connecting = TRUE; self->connect_cancel = g_cancellable_new();
    g_bus_get(G_BUS_TYPE_SESSION, self->connect_cancel, bus_ready, retain(self));
    status(self, FALSE, "Wayland 全局快捷键需要桌面门户授权，请在快捷键设置中启用。", NULL);
  } else if (GDK_IS_X11_DISPLAY(display)) {
    /* A separate X client makes conflicts with the pin module's GDK grabs
     * visible to XGrabKey, and prevents either owner from releasing the other. */
    self->xdisplay = XOpenDisplay(gdk_display_get_name(display));
    self->grabs = g_array_new(FALSE, FALSE, sizeof(Grab));
    if (self->xdisplay) {
      Bool supported = False;
      XkbSetDetectableAutoRepeat(self->xdisplay, True, &supported);
      self->detectable_repeat = supported;
      self->source = g_unix_fd_add_full(G_PRIORITY_DEFAULT, ConnectionNumber(self->xdisplay),
        G_IO_IN | G_IO_HUP | G_IO_ERR, x_events, retain(self), release);
    } else status(self, FALSE, "无法连接 X11；全局快捷键不可用。", NULL);
  } else status(self, FALSE, "当前显示后端未提供全局快捷键。", NULL);
  return self;
}
gboolean mc_global_shortcuts_is_portal(MCGlobalShortcuts *self) { return self && self->portal_backend; }
gboolean mc_global_shortcuts_busy(MCGlobalShortcuts *self) {
  return self && (self->connecting || self->replacing || (self->portal && mc_portal_shortcuts_busy(self->portal)));
}
void mc_global_shortcuts_replace(MCGlobalShortcuts *self, const MCShortcutBinding bindings[3], const char *parent_window,
    MCShortcutCommit commit, MCShortcutFinished finished, gpointer data) {
  if (!self || self->closed) { if (finished) finished(FALSE, "快捷键服务已关闭。", data); return; }
  if (mc_global_shortcuts_busy(self)) { if (finished) finished(FALSE, "请等待当前快捷键申请完成。", data); return; }
  if (self->portal_backend) {
    if (self->portal) mc_portal_shortcuts_replace(self->portal, bindings, parent_window, commit, finished, data);
    else if (finished) finished(FALSE, "GlobalShortcuts 门户不可用；可继续使用托盘操作。", data);
    return;
  }
  if (!self->xdisplay) { if (finished) finished(FALSE, "X11 全局快捷键不可用。", data); return; }
  retain(self); self->replacing = TRUE;
  const char *message = NULL;
  gboolean success = replace_x11(self, bindings, commit, data, &message);
  self->replacing = FALSE;
  schedule_queued_events(self);
  if (!self->closed && success) status(self, self->grabs->len != 0, message, NULL);
  /* This synchronous transaction owns its completion even if the commit or
   * state callback closes the manager. The caller must still release its data. */
  if (finished) finished(self->closed ? FALSE : success,
    self->closed ? "快捷键服务已关闭。" : message, data);
  release(self);
}
void mc_global_shortcuts_close(MCGlobalShortcuts *self) {
  if (!self || self->closed) return;
  self->closed = TRUE;
  if (self->connect_cancel) g_cancellable_cancel(self->connect_cancel);
  if (self->portal) { mc_portal_shortcuts_close(self->portal); self->portal = NULL; }
  if (self->source) { g_source_remove(self->source); self->source = 0; }
  if (self->queued_events) { g_source_remove(self->queued_events); self->queued_events = 0; }
  if (self->xdisplay && self->grabs) ungrab_difference(self, self->grabs, NULL);
  release(self);
}

typedef struct {
  unsigned actions[3], commits, finishes;
  gboolean allow_commit, success;
  MCGlobalShortcuts *close_on_commit;
} ShortcutProbe;
static void smoke_action(unsigned index, gpointer data) {
  if (index < 3) ((ShortcutProbe *)data)->actions[index]++;
}
static gboolean smoke_commit(const MCShortcutBinding bindings[3], const char *const labels[3], gpointer data) {
  (void)bindings; (void)labels;
  ShortcutProbe *probe = data; probe->commits++;
  if (probe->close_on_commit) {
    MCGlobalShortcuts *self = probe->close_on_commit; probe->close_on_commit = NULL;
    mc_global_shortcuts_close(self);
  }
  return probe->allow_commit;
}
static void smoke_finished(gboolean success, const char *message, gpointer data) {
  (void)message;
  ShortcutProbe *probe = data; probe->success = success; probe->finishes++;
}
static gboolean smoke_deadline(gpointer data) { *(gboolean *)data = TRUE; return G_SOURCE_REMOVE; }
static gboolean await_action(ShortcutProbe *probe, unsigned index, unsigned count) {
  gboolean expired = FALSE;
  guint timer = g_timeout_add(1000, smoke_deadline, &expired);
  while (probe->actions[index] < count && !expired) g_main_context_iteration(NULL, TRUE);
  if (!expired) g_source_remove(timer);
  if (probe->actions[index] != count) g_printerr("Global shortcut action %u: got %u expected %u.\n", index, probe->actions[index], count);
  return probe->actions[index] == count;
}
typedef Bool (*FakeKey)(Display *, unsigned int, Bool, unsigned long);
static void inject_shortcut(Display *display, FakeKey fake, MCShortcutBinding binding, gboolean repeat) {
  const KeySym modifiers[] = {XK_Control_L, XK_Alt_L, XK_Shift_L, XK_Super_L};
  for (unsigned bit = 0; bit < 4; bit++)
    if (binding.mods & (1 << bit)) fake(display, XKeysymToKeycode(display, modifiers[bit]), True, CurrentTime);
  KeyCode code = XKeysymToKeycode(display, keysym(binding.key));
  fake(display, code, True, CurrentTime);
  if (repeat) fake(display, code, True, CurrentTime);
  fake(display, code, False, CurrentTime);
  for (int bit = 3; bit >= 0; bit--)
    if (binding.mods & (1 << bit)) fake(display, XKeysymToKeycode(display, modifiers[bit]), False, CurrentTime);
  XSync(display, False);
}
static gboolean smoke_foreign_grab(Display *display, MCShortcutBinding binding) {
  XSync(display, False); trapped_display = display; trapped_error = 0;
  previous_error_handler = XSetErrorHandler(grab_error);
  XGrabKey(display, XKeysymToKeycode(display, keysym(binding.key)), xmods(binding.mods),
    DefaultRootWindow(display), False, GrabModeAsync, GrabModeAsync);
  XSync(display, False); XSetErrorHandler(previous_error_handler); trapped_display = NULL;
  return trapped_error == 0;
}
static void smoke_foreign_release(Display *display, MCShortcutBinding binding) {
  XUngrabKey(display, XKeysymToKeycode(display, keysym(binding.key)), xmods(binding.mods), DefaultRootWindow(display));
  XSync(display, False);
}
gboolean mc_global_shortcuts_x11_smoke(void) {
  GdkDisplay *display = gdk_display_get_default();
  if (!GDK_IS_X11_DISPLAY(display)) { g_printerr("Global shortcut fixture requires Xvfb/X11.\n"); return FALSE; }
  void *library = dlopen("libXtst.so.6", RTLD_NOW | RTLD_LOCAL);
  FakeKey fake = library ? (FakeKey)dlsym(library, "XTestFakeKeyEvent") : NULL;
  Display *injector = XOpenDisplay(gdk_display_get_name(display));
  if (!fake || !injector) {
    g_printerr("Global shortcut fixture requires libXtst and an X11 connection.\n");
    if (library) dlclose(library);
    if (injector) XCloseDisplay(injector);
    return FALSE;
  }
  ShortcutProbe probe = {.allow_commit = TRUE};
  const MCShortcutDescriptor descriptors[3] = {{"first", "First action"}, {"second", "Second action"}, {"third", "Third action"}};
  MCGlobalShortcuts *self = mc_global_shortcuts_new(display, descriptors, smoke_action, NULL, &probe);
  if (!self->xdisplay) { mc_global_shortcuts_close(self); XCloseDisplay(injector); dlclose(library); return FALSE; }
  MCShortcutBinding bindings[3] = {{261,7},{262,7},{263,7}}; /* Ctrl+Alt+Shift+F6/F7/F8 */
  MCShortcutBinding candidate[3]; memcpy(candidate, bindings, sizeof(candidate)); candidate[0].key = 264;
  mc_global_shortcuts_replace(self, bindings, "", smoke_commit, smoke_finished, &probe);
  gboolean ok = probe.success && probe.commits == 1 && probe.finishes == 1;
  for (unsigned i = 0; i < 3; i++) { inject_shortcut(injector, fake, bindings[i], FALSE); ok = await_action(&probe, i, 1) && ok; }
  XkbStateRec prior = {0};
  gboolean have_state = XkbGetState(injector, XkbUseCoreKbd, &prior) == Success;
  if (have_state) {
    XkbLockModifiers(injector, XkbUseCoreKbd, self->locks, self->locks); XSync(injector, False);
    inject_shortcut(injector, fake, bindings[0], FALSE); ok = await_action(&probe, 0, 2) && ok;
    XkbLockModifiers(injector, XkbUseCoreKbd, self->locks, prior.locked_mods); XSync(injector, False);
  } else ok = FALSE;
  inject_shortcut(injector, fake, bindings[0], TRUE); ok = await_action(&probe, 0, 3) && ok;
  gboolean blocked = smoke_foreign_grab(injector, candidate[0]); ok = blocked && ok;
  unsigned commits = probe.commits;
  mc_global_shortcuts_replace(self, candidate, "", smoke_commit, smoke_finished, &probe);
  ok = !probe.success && probe.commits == commits && ok;
  inject_shortcut(injector, fake, bindings[0], FALSE); ok = await_action(&probe, 0, 4) && ok;
  if (blocked) smoke_foreign_release(injector, candidate[0]);
  probe.allow_commit = FALSE;
  mc_global_shortcuts_replace(self, candidate, "", smoke_commit, smoke_finished, &probe);
  ok = !probe.success && probe.commits == commits + 1 && ok;
  gboolean released = smoke_foreign_grab(injector, candidate[0]); ok = released && ok;
  if (released) smoke_foreign_release(injector, candidate[0]);
  inject_shortcut(injector, fake, bindings[0], FALSE); ok = await_action(&probe, 0, 5) && ok;
  probe.allow_commit = TRUE;
  mc_global_shortcuts_replace(self, candidate, "", smoke_commit, smoke_finished, &probe);
  ok = probe.success && ok;
  released = smoke_foreign_grab(injector, bindings[0]); ok = released && ok;
  if (released) smoke_foreign_release(injector, bindings[0]);
  inject_shortcut(injector, fake, candidate[0], FALSE); ok = await_action(&probe, 0, 6) && ok;
  mc_global_shortcuts_close(self);
  for (unsigned i = 0; i < 3; i++) {
    released = smoke_foreign_grab(injector, candidate[i]); ok = released && ok;
    if (released) smoke_foreign_release(injector, candidate[i]);
  }
  /* A commit may synchronously close its owner; completion still frees the
   * caller transaction, and speculative native grabs cannot survive it. */
  self = mc_global_shortcuts_new(display, descriptors, smoke_action, NULL, &probe);
  probe.close_on_commit = self;
  unsigned finishes = probe.finishes;
  mc_global_shortcuts_replace(self, candidate, "", smoke_commit, smoke_finished, &probe);
  ok = !probe.success && probe.finishes == finishes + 1 && ok;
  released = smoke_foreign_grab(injector, candidate[0]); ok = released && ok;
  if (released) smoke_foreign_release(injector, candidate[0]);
  XCloseDisplay(injector); dlclose(library);
  g_print("Linux global shortcuts smoke %s: real XTest actions, lock modifiers, repeat, foreign conflicts, rollback and release.\n",
    ok ? "passed" : "FAILED");
  return ok;
}
