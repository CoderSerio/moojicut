#include "portal_shortcuts.h"
#include <string.h>

#define PORTAL "org.freedesktop.portal.Desktop"
#define DESKTOP "/org/freedesktop/portal/desktop"
#define SHORTCUTS "org.freedesktop.portal.GlobalShortcuts"
#define REQUEST "org.freedesktop.portal.Request"
#define SESSION "org.freedesktop.portal.Session"
typedef enum { CAPABILITY, CREATE, BIND, REFRESH } Phase;
typedef struct Operation Operation;
struct MCPortalShortcuts {
  unsigned refs;
  gboolean closed;
  GDBusConnection *bus;
  guint events, sessions, owner;
  gulong disconnected;
  MCShortcutAction action;
  MCShortcutState state;
  gpointer data;
  char *active;
  char *ids[3], *descriptions[3];
  MCShortcutBinding bindings[3];
  char *labels[3];
  gboolean pressed[3];
  Operation *pending, *refresh;
};
struct Operation {
  unsigned refs;
  MCPortalShortcuts *self;
  Phase phase;
  gboolean done, committed;
  guint response, timeout;
  char *request, *session, *parent;
  MCShortcutBinding bindings[3];
  MCShortcutCommit commit;
  MCShortcutFinished finished;
  gpointer data;
};
static void operation_finish(Operation *, gboolean, const char *);
static void begin_request(Operation *, Phase);
static MCPortalShortcuts *retain(MCPortalShortcuts *s) { s->refs++; return s; }
static void release(MCPortalShortcuts *s) {
  if (--s->refs) return;
  for (unsigned i = 0; i < 3; i++) {
    g_free(s->labels[i]); g_free(s->ids[i]); g_free(s->descriptions[i]);
  }
  g_free(s->active); g_object_unref(s->bus); g_free(s);
}
static Operation *op_ref(Operation *p) { p->refs++; return p; }
static void op_unref(gpointer data) {
  Operation *p = data;
  if (--p->refs) return;
  g_free(p->request); g_free(p->session); g_free(p->parent);
  release(p->self); g_free(p);
}
static gboolean current(Operation *p) {
  return !p->done && !p->self->closed &&
    (p->phase == REFRESH ? p->self->refresh == p && !g_strcmp0(p->session, p->self->active)
                         : p->self->pending == p);
}
static void remote_close(MCPortalShortcuts *s, const char *path, const char *interface) {
  if (path && !g_dbus_connection_is_closed(s->bus))
    g_dbus_connection_call(s->bus, PORTAL, path, interface, "Close", NULL, NULL,
      G_DBUS_CALL_FLAGS_NONE, 3000, NULL, NULL, NULL);
}
static void clear_request(Operation *p) {
  if (p->response) { guint id = p->response; p->response = 0; g_dbus_connection_signal_unsubscribe(p->self->bus, id); }
  g_clear_pointer(&p->request, g_free);
}
static void state_changed(MCPortalShortcuts *s, const char *message) {
  gboolean active = s->active != NULL;
  for (unsigned i = 0; i < 3; i++) if (s->bindings[i].key && (!s->labels[i] || !*s->labels[i])) active = FALSE;
  if (!s->closed && s->state) s->state(active, message, (const char *const *)s->labels, s->data);
}
static void operation_finish(Operation *p, gboolean success, const char *message) {
  if (p->done) return;
  op_ref(p);
  MCPortalShortcuts *s = p->self;
  p->done = TRUE;
  if (!success) {
    remote_close(s, p->request, REQUEST);
    if (p->phase != REFRESH) remote_close(s, p->session, SESSION);
  }
  clear_request(p);
  if (p->timeout) { guint id = p->timeout; p->timeout = 0; g_source_remove(id); }
  if (s->pending == p) { s->pending = NULL; op_unref(p); }
  if (s->refresh == p) { s->refresh = NULL; op_unref(p); }
  if (!s->closed && p->finished) p->finished(success, message, p->data);
  op_unref(p);
}
static gboolean timed_out(gpointer data) {
  Operation *p = data; p->timeout = 0;
  operation_finish(p, FALSE, "桌面快捷键授权超时，原有配置与会话已保留。");
  return G_SOURCE_REMOVE;
}
static Operation *operation_new(MCPortalShortcuts *s) {
  Operation *p = g_new0(Operation, 1); p->refs = 1; p->self = retain(s);
  p->timeout = g_timeout_add_full(G_PRIORITY_DEFAULT, 120000, timed_out, op_ref(p), op_unref);
  return p;
}
static char *token(void) {
  char *value = g_uuid_string_random();
  for (char *c = value; *c; c++) if (*c == '-') *c = '_';
  char *result = g_strconcat("shortcut_", value, NULL); g_free(value); return result;
}
static char *path_for(MCPortalShortcuts *s, const char *kind, const char *part) {
  const char *name = g_dbus_connection_get_unique_name(s->bus);
  char *sender = g_strdup(name && *name == ':' ? name + 1 : "invalid");
  for (char *c = sender; *c; c++) if (*c == '.') *c = '_';
  char *result = g_strdup_printf(DESKTOP "/%s/%s/%s", kind, sender, part);
  g_free(sender); return result;
}
static char *trigger(MCShortcutBinding b) {
  GString *s = g_string_new(NULL);
  if (b.mods & 1) g_string_append(s, "CTRL+");
  if (b.mods & 2) g_string_append(s, "ALT+");
  if (b.mods & 4) g_string_append(s, "SHIFT+");
  if (b.mods & 8) g_string_append(s, "LOGO+");
  if (b.key >= 256) g_string_append_printf(s, "F%d", b.key - 255);
  else g_string_append_c(s, g_ascii_tolower((gchar)b.key));
  return g_string_free(s, FALSE);
}
static gboolean decode_labels(const MCPortalShortcuts *s, GVariant *results, const MCShortcutBinding bindings[3], char *labels[3]) {
  GVariant *array = g_variant_lookup_value(results, "shortcuts", G_VARIANT_TYPE("a(sa{sv})"));
  if (!array) return FALSE;
  GVariantIter iter; const char *id; GVariant *properties;
  gboolean seen[3] = {FALSE}; gboolean valid = TRUE;
  g_variant_iter_init(&iter, array);
  while (g_variant_iter_next(&iter, "(&s@a{sv})", &id, &properties)) {
    int index = -1;
    for (unsigned i = 0; i < 3; i++) if (!strcmp(id, s->ids[i])) index = (int)i;
    const char *label = NULL;
    if (index < 0 || !bindings[index].key || seen[index] ||
        !g_variant_lookup(properties, "trigger_description", "&s", &label) || !*label || strlen(label) > 4096) valid = FALSE;
    else { seen[index] = TRUE; labels[index] = g_strdup(label); }
    g_variant_unref(properties);
  }
  for (unsigned i = 0; i < 3; i++) if (bindings[i].key && !seen[i]) valid = FALSE;
  g_variant_unref(array); return valid;
}
static void response(GDBusConnection *bus, const char *sender, const char *path,
    const char *interface, const char *signal, GVariant *parameters, gpointer data) {
  (void)bus; (void)sender; (void)path; (void)interface; (void)signal;
  Operation *p = op_ref(data); MCPortalShortcuts *s = p->self;
  if (!g_variant_is_of_type(parameters, G_VARIANT_TYPE("(ua{sv})"))) {
    if (current(p)) operation_finish(p, FALSE, "桌面返回了无效的快捷键响应。");
    op_unref(p); return;
  }
  guint code; GVariant *results;
  g_variant_get(parameters, "(u@a{sv})", &code, &results);
  if (!current(p)) { if (p->phase == CREATE) remote_close(s, p->session, SESSION); goto out; }
  if (code) { operation_finish(p, FALSE, code == 1 ? "已取消桌面快捷键授权，原有配置与会话已保留。" : "桌面拒绝了快捷键授权，原有配置与会话已保留。"); goto out; }
  if (p->phase == CREATE) {
    const char *session = NULL;
    if (!g_variant_lookup(results, "session_handle", "&s", &session) || strcmp(session, p->session))
      operation_finish(p, FALSE, "桌面返回了无效的快捷键会话。");
    else begin_request(p, BIND);
  } else {
    char *labels[3] = {NULL};
    gboolean complete = decode_labels(s, results, p->bindings, labels);
    if (p->phase == REFRESH) {
      for (unsigned i = 0; i < 3; i++) { g_free(s->labels[i]); s->labels[i] = g_steal_pointer(&labels[i]); s->pressed[i] = FALSE; }
      state_changed(s, complete ? "桌面已更新全局快捷键。" : "部分桌面快捷键已停用，请重新授权。");
      operation_finish(p, TRUE, "");
    } else if (!complete) operation_finish(p, FALSE, "桌面未授权全部快捷键，原有配置与会话已保留。");
    else if (p->commit && !p->commit(p->bindings, (const char *const *)labels, p->data))
      operation_finish(p, FALSE, "快捷键保存失败，原有配置与会话已保留。");
    else if (current(p)) {
      p->committed = TRUE;
      char *old = s->active; s->active = g_strdup(p->session);
      memcpy(s->bindings, p->bindings, sizeof(s->bindings));
      for (unsigned i = 0; i < 3; i++) { g_free(s->labels[i]); s->labels[i] = g_steal_pointer(&labels[i]); s->pressed[i] = FALSE; }
      remote_close(s, old, SESSION); g_free(old);
      if (s->refresh) operation_finish(s->refresh, FALSE, "");
      state_changed(s, "桌面全局快捷键已生效（实际按键由桌面授权决定）。");
      operation_finish(p, TRUE, "桌面全局快捷键已生效。");
    }
    for (unsigned i = 0; i < 3; i++) g_free(labels[i]);
  }
out:
  g_variant_unref(results); op_unref(p);
}
typedef struct { Operation *op; Phase phase; char *request; } MethodCall;
static void method_done(GObject *object, GAsyncResult *result, gpointer data) {
  MethodCall *call = data; Operation *p = call->op; GError *error = NULL;
  GVariant *reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(object), result, &error);
  if (p->done && !p->committed) {
    if (reply) { const char *path; g_variant_get(reply, "(&o)", &path); remote_close(p->self, path, REQUEST); }
    if (call->phase != REFRESH) remote_close(p->self, p->session, SESSION);
  } else if (current(p) && p->phase == call->phase && !g_strcmp0(p->request, call->request)) {
    if (!reply) operation_finish(p, FALSE, "桌面快捷键接口不可用或请求失败；原有配置与会话已保留。");
    else {
    const char *path; g_variant_get(reply, "(&o)", &path);
    if (strcmp(path, p->request)) { remote_close(p->self, path, REQUEST); operation_finish(p, FALSE, "桌面返回了不匹配的快捷键请求。"); }
    }
  }
  // Response is allowed to precede the method reply and advance the operation.
  // A delayed CreateSession reply must not compare itself with Bind's token,
  // and a delayed successful Bind reply must never close the committed session.
  g_clear_pointer(&reply, g_variant_unref); g_clear_error(&error); op_unref(p);
  g_free(call->request); g_free(call);
}
static void begin_request(Operation *p, Phase phase) {
  clear_request(p); p->phase = phase;
  char *part = token(); p->request = path_for(p->self, "request", part);
  GVariantBuilder options; g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&options, "{sv}", "handle_token", g_variant_new_string(part)); g_free(part);
  GVariant *args; const char *method;
  if (phase == CREATE) {
    part = token(); g_free(p->session); p->session = path_for(p->self, "session", part);
    g_variant_builder_add(&options, "{sv}", "session_handle_token", g_variant_new_string(part)); g_free(part);
    args = g_variant_new("(a{sv})", &options); method = "CreateSession";
  } else if (phase == BIND) {
    GVariantBuilder shortcuts; g_variant_builder_init(&shortcuts, G_VARIANT_TYPE("a(sa{sv})"));
    for (unsigned i = 0; i < 3; i++) if (p->bindings[i].key) {
      GVariantBuilder props; g_variant_builder_init(&props, G_VARIANT_TYPE_VARDICT);
      char *preferred = trigger(p->bindings[i]);
      g_variant_builder_add(&props, "{sv}", "description", g_variant_new_string(p->self->descriptions[i]));
      g_variant_builder_add(&props, "{sv}", "preferred_trigger", g_variant_new_string(preferred)); g_free(preferred);
      g_variant_builder_add(&shortcuts, "(sa{sv})", p->self->ids[i], &props);
    }
    args = g_variant_new("(oa(sa{sv})sa{sv})", p->session, &shortcuts, p->parent, &options); method = "BindShortcuts";
  } else { args = g_variant_new("(oa{sv})", p->session, &options); method = "ListShortcuts"; }
  p->response = g_dbus_connection_signal_subscribe(p->self->bus, PORTAL, REQUEST, "Response", p->request,
    NULL, G_DBUS_SIGNAL_FLAGS_NONE, response, op_ref(p), op_unref);
  MethodCall *call = g_new0(MethodCall, 1); call->op = op_ref(p); call->phase = phase; call->request = g_strdup(p->request);
  g_dbus_connection_call(p->self->bus, PORTAL, DESKTOP, SHORTCUTS, method, args, G_VARIANT_TYPE("(o)"),
    G_DBUS_CALL_FLAGS_NONE, 10000, NULL, method_done, call);
}
static void capability_done(GObject *object, GAsyncResult *result, gpointer data) {
  Operation *p = data; GError *error = NULL;
  GVariant *reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(object), result, &error);
  if (current(p)) {
    GVariant *version = NULL;
    if (reply) g_variant_get(reply, "(v)", &version);
    if (!version || !g_variant_is_of_type(version, G_VARIANT_TYPE_UINT32) || g_variant_get_uint32(version) < 1)
      operation_finish(p, FALSE, "当前桌面不支持 GlobalShortcuts portal，Wayland 全局快捷键不可用。");
    else begin_request(p, CREATE);
    g_clear_pointer(&version, g_variant_unref);
  }
  g_clear_pointer(&reply, g_variant_unref); g_clear_error(&error); op_unref(p);
}
static void lost_session(MCPortalShortcuts *s, const char *message) {
  if (s->pending) operation_finish(s->pending, FALSE, message);
  if (s->refresh) operation_finish(s->refresh, FALSE, message);
  g_clear_pointer(&s->active, g_free);
  for (unsigned i = 0; i < 3; i++) { g_clear_pointer(&s->labels[i], g_free); s->pressed[i] = FALSE; }
  state_changed(s, message);
}
static void event_signal(GDBusConnection *bus, const char *sender, const char *path,
    const char *interface, const char *signal, GVariant *parameters, gpointer data) {
  (void)bus; (void)sender; (void)interface;
  MCPortalShortcuts *s = retain(data);
  if (s->closed) goto out;
  if (!strcmp(signal, "Closed")) {
    if (!g_strcmp0(path, s->active)) lost_session(s, "桌面已关闭全局快捷键会话，请重新授权。");
    else if (s->pending && !g_strcmp0(path, s->pending->session)) operation_finish(s->pending, FALSE, "桌面关闭了待授权快捷键会话，原有配置与会话已保留。");
  } else if (!strcmp(signal, "ShortcutsChanged")) {
    if (!g_variant_is_of_type(parameters, G_VARIANT_TYPE("(oa(sa{sv}))"))) goto out;
    const char *session; GVariant *values; g_variant_get(parameters, "(&o@a(sa{sv}))", &session, &values);
    if (!g_strcmp0(session, s->active) && !s->refresh) {
      Operation *p = s->refresh = operation_new(s); p->phase = REFRESH; p->session = g_strdup(session);
      memcpy(p->bindings, s->bindings, sizeof(p->bindings)); begin_request(p, REFRESH);
    }
    g_variant_unref(values);
  } else {
    if ((strcmp(signal, "Activated") && strcmp(signal, "Deactivated")) ||
        !g_variant_is_of_type(parameters, G_VARIANT_TYPE("(osta{sv})"))) goto out;
    const char *session, *id; guint64 stamp; GVariant *options;
    g_variant_get(parameters, "(&o&st@a{sv})", &session, &id, &stamp, &options); (void)stamp;
    if (!g_strcmp0(session, s->active)) for (unsigned i = 0; i < 3; i++) {
      if (!strcmp(id, s->ids[i]) && s->bindings[i].key && s->labels[i] && *s->labels[i]) {
        if (!strcmp(signal, "Deactivated")) s->pressed[i] = FALSE;
        else if (!strcmp(signal, "Activated") && !s->pressed[i]) { s->pressed[i] = TRUE; if (s->action) s->action(i, s->data); }
        break;
      }
    }
    g_variant_unref(options);
  }
out: release(s);
}
static void owner_changed(GDBusConnection *bus, const char *sender, const char *path,
    const char *interface, const char *signal, GVariant *parameters, gpointer data) {
  (void)bus; (void)sender; (void)path; (void)interface; (void)signal;
  MCPortalShortcuts *s = retain(data); const char *name, *old, *next;
  g_variant_get(parameters, "(&s&s&s)", &name, &old, &next); (void)name; (void)next;
  if (!s->closed && *old) lost_session(s, "桌面快捷键服务已断开，请重新授权。");
  release(s);
}
static void disconnected(GDBusConnection *bus, gboolean remote, GError *error, gpointer data) {
  (void)bus; (void)remote; (void)error; MCPortalShortcuts *s = retain(data);
  if (!s->closed) lost_session(s, "桌面会话总线已断开，全局快捷键不可用。");
  release(s);
}
MCPortalShortcuts *mc_portal_shortcuts_new(GDBusConnection *bus, const MCShortcutDescriptor descriptors[3],
    MCShortcutAction action, MCShortcutState state, gpointer data) {
  g_return_val_if_fail(G_IS_DBUS_CONNECTION(bus), NULL);
  g_return_val_if_fail(descriptors != NULL, NULL);
  for (unsigned i = 0; i < 3; i++) {
    g_return_val_if_fail(descriptors[i].id && *descriptors[i].id && g_utf8_validate(descriptors[i].id, -1, NULL), NULL);
    g_return_val_if_fail(descriptors[i].description && *descriptors[i].description && g_utf8_validate(descriptors[i].description, -1, NULL), NULL);
    for (unsigned j = 0; j < i; j++) g_return_val_if_fail(strcmp(descriptors[i].id, descriptors[j].id) != 0, NULL);
  }
  MCPortalShortcuts *s = g_new0(MCPortalShortcuts, 1); s->refs = 1; s->bus = g_object_ref(bus);
  s->action = action; s->state = state; s->data = data;
  for (unsigned i = 0; i < 3; i++) {
    s->ids[i] = g_strdup(descriptors[i].id); s->descriptions[i] = g_strdup(descriptors[i].description);
  }
  s->events = g_dbus_connection_signal_subscribe(bus, PORTAL, SHORTCUTS, NULL, DESKTOP, NULL, G_DBUS_SIGNAL_FLAGS_NONE, event_signal, s, NULL);
  s->sessions = g_dbus_connection_signal_subscribe(bus, PORTAL, SESSION, "Closed", NULL, NULL, G_DBUS_SIGNAL_FLAGS_NONE, event_signal, s, NULL);
  s->owner = g_dbus_connection_signal_subscribe(bus, "org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged", "/org/freedesktop/DBus", PORTAL, G_DBUS_SIGNAL_FLAGS_NONE, owner_changed, s, NULL);
  s->disconnected = g_signal_connect(bus, "closed", G_CALLBACK(disconnected), s);
  return s;
}
gboolean mc_portal_shortcuts_busy(MCPortalShortcuts *s) { return s && !s->closed && s->pending != NULL; }
void mc_portal_shortcuts_replace(MCPortalShortcuts *s, const MCShortcutBinding bindings[3], const char *parent,
    MCShortcutCommit commit, MCShortcutFinished finished, gpointer data) {
  if (!s || s->closed) return;
  if (s->pending) { if (finished) finished(FALSE, "正在等待桌面授权，请先完成或取消当前请求。", data); return; }
  Operation *p = s->pending = operation_new(s); p->phase = CAPABILITY;
  memcpy(p->bindings, bindings, sizeof(p->bindings)); p->parent = g_strdup(parent ? parent : "");
  p->commit = commit; p->finished = finished; p->data = data;
  if (!bindings[0].key && !bindings[1].key && !bindings[2].key) {
    // A local transaction still owns its completion callback, including if
    // commit/state synchronously closes the manager. No portal prompt is needed.
    op_ref(p); const char *labels[3] = {NULL};
    gboolean saved = !commit || commit(bindings, labels, data);
    if (current(p) && saved) {
      remote_close(s, s->active, SESSION); g_clear_pointer(&s->active, g_free);
      memcpy(s->bindings, bindings, sizeof(s->bindings));
      for (unsigned i = 0; i < 3; i++) { g_clear_pointer(&s->labels[i], g_free); s->pressed[i] = FALSE; }
      if (s->refresh) operation_finish(s->refresh, FALSE, "");
      state_changed(s, "全部全局快捷键已停用。");
    }
    operation_finish(p, saved, saved ? "全部全局快捷键已停用。" : "快捷键保存失败，原有配置与会话已保留。");
    op_unref(p); return;
  }
  g_dbus_connection_call(s->bus, PORTAL, DESKTOP, "org.freedesktop.DBus.Properties", "Get",
    g_variant_new("(ss)", SHORTCUTS, "version"), G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE,
    5000, NULL, capability_done, op_ref(p));
}
void mc_portal_shortcuts_close(MCPortalShortcuts *s) {
  if (!s || s->closed) return;
  s->closed = TRUE;
  if (s->pending) {
    Operation *p = op_ref(s->pending);
    MCShortcutFinished finished = p->finished; gpointer data = p->data; p->finished = NULL;
    operation_finish(p, FALSE, "");
    if (finished) finished(FALSE, "已取消桌面快捷键请求。", data);
    op_unref(p);
  }
  if (s->refresh) operation_finish(s->refresh, FALSE, "");
  remote_close(s, s->active, SESSION);
  g_dbus_connection_signal_unsubscribe(s->bus, s->events);
  g_dbus_connection_signal_unsubscribe(s->bus, s->sessions);
  g_dbus_connection_signal_unsubscribe(s->bus, s->owner);
  g_signal_handler_disconnect(s->bus, s->disconnected);
  release(s);
}
