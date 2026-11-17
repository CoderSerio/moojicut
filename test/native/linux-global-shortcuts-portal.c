/* Standalone GIO fixture. GTestDBus owns a private bus: never use the user's
 * portal or show a permission dialog. No GTK/compositor dependency. */
#include "platform/linux/input/portal_shortcuts.h"
#include <string.h>
#define SERVICE "org.freedesktop.portal.Desktop"
#define DESKTOP "/org/freedesktop/portal/desktop"
#define GLOBAL "org.freedesktop.portal.GlobalShortcuts"
#define REQUEST "org.freedesktop.portal.Request"
#define SESSION "org.freedesktop.portal.Session"
static const MCShortcutDescriptor descriptors[3] = {
  {"capture", "截图"}, {"record", "开始录屏"}, {"stop", "停止录屏"}
};
static const char xml[] =
  "<node><interface name='org.freedesktop.portal.GlobalShortcuts'>"
  "<property name='version' type='u' access='read'/>"
  "<method name='CreateSession'><arg type='a{sv}' direction='in'/><arg type='o' direction='out'/></method>"
  "<method name='BindShortcuts'><arg type='o' direction='in'/><arg type='a(sa{sv})' direction='in'/>"
  "<arg type='s' direction='in'/><arg type='a{sv}' direction='in'/><arg type='o' direction='out'/></method>"
  "<method name='ListShortcuts'><arg type='o' direction='in'/><arg type='a{sv}' direction='in'/><arg type='o' direction='out'/></method>"
  "<signal name='Activated'><arg type='o'/><arg type='s'/><arg type='t'/><arg type='a{sv}'/></signal>"
  "<signal name='Deactivated'><arg type='o'/><arg type='s'/><arg type='t'/><arg type='a{sv}'/></signal>"
  "<signal name='ShortcutsChanged'><arg type='o'/><arg type='a(sa{sv})'/></signal>"
  "</interface><interface name='org.freedesktop.portal.Request'>"
  "<method name='Close'/><signal name='Response'><arg type='u'/><arg type='a{sv}'/></signal>"
  "</interface><interface name='org.freedesktop.portal.Session'>"
  "<method name='Close'/><signal name='Closed'><arg type='a{sv}'/></signal></interface></node>";
typedef enum { NORMAL, CANCEL, PARTIAL, HOLD } Mode;
typedef struct {
  GDBusConnection *bus;
  GDBusNodeInfo *info;
  GHashTable *closed, *values;
  GArray *registrations;
  guint version, creates, binds, lists;
  Mode mode;
  char *last_session, *held_path;
  GVariant *held_results;
  GDBusMethodInvocation *held_call;
} Mock;
typedef struct {
  guint finished, commits, states, actions[3];
  gboolean success, reject_commit, active;
  MCPortalShortcuts *close_on_commit;
  char *labels[3];
} Client;
static GVariant *empty(void) { return g_variant_new_array(G_VARIANT_TYPE("{sv}"), NULL, 0); }
static char *handle(const char *sender, const char *kind, const char *token) {
  char *name = g_strdup(sender + 1);
  for (char *p = name; *p; p++) if (*p == '.') *p = '_';
  char *path = g_strdup_printf(DESKTOP "/%s/%s/%s", kind, name, token); g_free(name); return path;
}
static void respond(Mock *m, const char *path, guint code, GVariant *results) {
  GError *error = NULL;
  g_dbus_connection_emit_signal(m->bus, NULL, path, REQUEST, "Response",
    g_variant_new("(u@a{sv})", code, g_variant_ref(results)), &error);
  g_assert_no_error(error);
}
static void method(GDBusConnection *, const char *, const char *, const char *, const char *, GVariant *, GDBusMethodInvocation *, gpointer);
static GVariant *property(GDBusConnection *bus, const char *sender, const char *path,
    const char *interface, const char *name, GError **error, gpointer data) {
  (void)bus; (void)sender; (void)path; (void)interface; (void)name; (void)error;
  return g_variant_new_uint32(((Mock *)data)->version);
}
static const GDBusInterfaceVTable vtable = {.method_call = method, .get_property = property};
static void register_path(Mock *m, const char *path, const char *interface) {
  GError *error = NULL;
  guint registration = g_dbus_connection_register_object(m->bus, path,
    g_dbus_node_info_lookup_interface(m->info, interface), &vtable, m, NULL, &error);
  g_assert_no_error(error); g_assert_cmpuint(registration, >, 0);
  g_array_append_val(m->registrations, registration);
}
static GVariant *bound_values(GVariant *input, gboolean partial) {
  GVariantBuilder result; g_variant_builder_init(&result, G_VARIANT_TYPE("a(sa{sv})"));
  GVariantIter iter; const char *id; GVariant *dict; unsigned index = 0;
  g_variant_iter_init(&iter, input);
  while (g_variant_iter_next(&iter, "(&s@a{sv})", &id, &dict)) {
    const char *preferred = NULL, *description = NULL;
    g_assert_true(g_variant_lookup(dict, "preferred_trigger", "&s", &preferred));
    g_assert_true(g_variant_lookup(dict, "description", "&s", &description));
    gboolean found = FALSE;
    for (unsigned i = 0; i < 3; i++) if (!strcmp(id, descriptors[i].id)) {
      g_assert_cmpstr(description, ==, descriptors[i].description); found = TRUE;
    }
    g_assert_true(found);
    if (!strcmp(id, "capture")) g_assert_cmpstr(preferred, ==, "CTRL+SHIFT+1");
    if (!strcmp(id, "record")) g_assert_cmpstr(preferred, ==, "ALT+F1");
    if (!strcmp(id, "stop")) g_assert_cmpstr(preferred, ==, "LOGO+x");
    if (!partial || index == 0) {
      GVariantBuilder props; g_variant_builder_init(&props, G_VARIANT_TYPE_VARDICT);
      char *actual = g_strdup_printf("实际桌面按键 %s", id);
      g_variant_builder_add(&props, "{sv}", "trigger_description", g_variant_new_string(actual));
      g_variant_builder_add(&result, "(sa{sv})", id, &props); g_free(actual);
    }
    g_variant_unref(dict); index++;
  }
  return g_variant_builder_end(&result);
}
static void method(GDBusConnection *bus, const char *sender, const char *path, const char *interface,
    const char *name, GVariant *args, GDBusMethodInvocation *call, gpointer data) {
  (void)bus; Mock *m = data;
  if (!strcmp(name, "Close")) {
    g_assert_true(!strcmp(interface, REQUEST) || !strcmp(interface, SESSION));
    g_hash_table_add(m->closed, g_strdup(path));
    g_dbus_method_invocation_return_value(call, NULL); return;
  }
  GVariant *options, *shortcuts = NULL; const char *session = NULL, *parent = NULL;
  if (!strcmp(name, "CreateSession")) g_variant_get(args, "(@a{sv})", &options);
  else if (!strcmp(name, "BindShortcuts")) g_variant_get(args, "(&o@a(sa{sv})&s@a{sv})", &session, &shortcuts, &parent, &options);
  else g_variant_get(args, "(&o@a{sv})", &session, &options);
  const char *part = NULL;
  g_assert_true(g_variant_lookup(options, "handle_token", "&s", &part));
  char *request = handle(sender, "request", part); register_path(m, request, REQUEST);
  GVariantBuilder results; g_variant_builder_init(&results, G_VARIANT_TYPE_VARDICT);
  if (!strcmp(name, "CreateSession")) {
    g_assert_true(g_variant_lookup(options, "session_handle_token", "&s", &part));
    g_free(m->last_session); m->last_session = handle(sender, "session", part);
    register_path(m, m->last_session, SESSION); m->creates++;
    g_variant_builder_add(&results, "{sv}", "session_handle", g_variant_new_string(m->last_session));
  } else if (!strcmp(name, "BindShortcuts")) {
    g_assert_cmpstr(parent, ==, ""); m->binds++;
    GVariant *values = g_variant_ref_sink(bound_values(shortcuts, m->mode == PARTIAL));
    g_hash_table_replace(m->values, g_strdup(session), g_variant_ref(values));
    g_variant_builder_add(&results, "{sv}", "shortcuts", values); g_variant_unref(values);
  } else {
    m->lists++;
    GVariant *values = g_hash_table_lookup(m->values, session); g_assert_nonnull(values);
    g_variant_builder_add(&results, "{sv}", "shortcuts", values);
  }
  GVariant *result = g_variant_ref_sink(g_variant_builder_end(&results));
  if (m->mode == HOLD && !strcmp(name, "BindShortcuts")) {
    g_assert_null(m->held_call);
    m->held_call = g_object_ref(call); m->held_results = g_variant_ref(result); m->held_path = g_strdup(request);
  } else {
    // Deliberately send Response BEFORE the initial method reply. Clients must
    // pre-subscribe and must not confuse a late Create reply with Bind's token.
    respond(m, request, m->mode == CANCEL && !strcmp(name, "BindShortcuts") ? 1 : 0, result);
    g_dbus_method_invocation_return_value(call, g_variant_new("(o)", request));
  }
  g_variant_unref(result); g_variant_unref(options);
  if (shortcuts) g_variant_unref(shortcuts);
  g_free(request);
}
static gboolean commit(const MCShortcutBinding bindings[3], const char *const labels[3], gpointer data) {
  Client *c = data; c->commits++;
  for (unsigned i = 0; i < 3; i++) if (bindings[i].key) g_assert_nonnull(labels[i]);
  if (c->close_on_commit) {
    MCPortalShortcuts *portal = c->close_on_commit; c->close_on_commit = NULL;
    mc_portal_shortcuts_close(portal);
  }
  return !c->reject_commit;
}
static void finished(gboolean success, const char *message, gpointer data) {
  Client *c = data; c->finished++; c->success = success; g_assert_nonnull(message);
}
static void state(gboolean active, const char *message, const char *const labels[3], gpointer data) {
  Client *c = data; c->states++; c->active = active; g_assert_nonnull(message);
  for (unsigned i = 0; i < 3; i++) { g_free(c->labels[i]); c->labels[i] = g_strdup(labels[i]); }
}
static void action(unsigned index, gpointer data) { g_assert_cmpuint(index, <, 3); ((Client *)data)->actions[index]++; }
static gboolean deadline(gpointer data) { *(gboolean *)data = TRUE; return G_SOURCE_REMOVE; }
static void wait_count(guint *value, guint wanted) {
  gboolean expired = FALSE; guint timer = g_timeout_add(4000, deadline, &expired);
  while (*value < wanted && !expired) g_main_context_iteration(NULL, TRUE);
  if (!expired) g_source_remove(timer);
  g_assert_cmpuint(*value, >=, wanted);
}
static void settle(void) {
  gboolean expired = FALSE;
  g_timeout_add(40, deadline, &expired);
  while (!expired) g_main_context_iteration(NULL, TRUE);
}
static void activation(Mock *m, const char *session, const char *id, gboolean on) {
  GError *error = NULL;
  g_dbus_connection_emit_signal(m->bus, NULL, DESKTOP, GLOBAL, on ? "Activated" : "Deactivated",
    g_variant_new("(ost@a{sv})", session, id, (guint64)123, empty()), &error); g_assert_no_error(error);
}
static GDBusConnection *connect_bus(const char *address) {
  GError *error = NULL;
  GDBusConnection *bus = g_dbus_connection_new_for_address_sync(address,
    G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT | G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION,
    NULL, NULL, &error); g_assert_no_error(error); return bus;
}
int main(int argc, char **argv) {
  g_test_init(&argc, &argv, NULL);
  GTestDBus *test = g_test_dbus_new(G_TEST_DBUS_NONE); g_test_dbus_up(test);
  Mock m = {0}; m.version = 1;
  m.bus = connect_bus(g_test_dbus_get_bus_address(test));
  GDBusConnection *bus = connect_bus(g_test_dbus_get_bus_address(test));
  GError *error = NULL;
  GVariant *reply = g_dbus_connection_call_sync(m.bus, "org.freedesktop.DBus", "/org/freedesktop/DBus",
    "org.freedesktop.DBus", "RequestName", g_variant_new("(su)", SERVICE, 0u), G_VARIANT_TYPE("(u)"),
    G_DBUS_CALL_FLAGS_NONE, 1000, NULL, &error); g_assert_no_error(error); g_variant_unref(reply);
  m.info = g_dbus_node_info_new_for_xml(xml, &error); g_assert_no_error(error);
  m.closed = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
  m.values = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, (GDestroyNotify)g_variant_unref);
  m.registrations = g_array_new(FALSE, FALSE, sizeof(guint)); register_path(&m, DESKTOP, GLOBAL);
  Client c = {0};
  MCShortcutDescriptor temporary[3]; char *temporary_ids[3], *temporary_descriptions[3];
  for (unsigned i = 0; i < 3; i++) {
    temporary_ids[i] = g_strdup(descriptors[i].id); temporary_descriptions[i] = g_strdup(descriptors[i].description);
    temporary[i] = (MCShortcutDescriptor){temporary_ids[i], temporary_descriptions[i]};
  }
  MCPortalShortcuts *portal = mc_portal_shortcuts_new(bus, temporary, action, state, &c);
  // Caller-owned descriptors may immediately be changed or destroyed.
  for (unsigned i = 0; i < 3; i++) {
    memset(temporary_ids[i], 'x', strlen(temporary_ids[i]));
    memset(temporary_descriptions[i], 'x', strlen(temporary_descriptions[i]));
    g_free(temporary_ids[i]); g_free(temporary_descriptions[i]);
  }
  const MCShortcutBinding bindings[3] = {{'1', 5}, {256, 2}, {'X', 8}};
  g_assert_cmpuint(m.creates, ==, 0); // construction cannot ask for permission
  mc_portal_shortcuts_replace(portal, bindings, "", commit, finished, &c);
  wait_count(&c.finished, 1); g_assert_true(c.success && c.active); g_assert_cmpuint(c.commits, ==, 1);
  g_assert_cmpstr(c.labels[0], ==, "实际桌面按键 capture");
  char *active = g_strdup(m.last_session); settle();
  g_assert_false(g_hash_table_contains(m.closed, active)); // late Bind reply cannot retire success
  activation(&m, active, "capture", TRUE); activation(&m, active, "capture", TRUE);
  wait_count(&c.actions[0], 1); settle(); g_assert_cmpuint(c.actions[0], ==, 1);
  activation(&m, active, "capture", FALSE); activation(&m, active, "capture", TRUE);
  wait_count(&c.actions[0], 2);
  // Denial and incomplete authorization leave the original session registered.
  for (Mode mode = CANCEL; mode <= PARTIAL; mode++) {
    m.mode = mode; guint count = c.finished;
    mc_portal_shortcuts_replace(portal, bindings, "", commit, finished, &c); wait_count(&c.finished, count + 1);
    g_assert_false(c.success); g_assert_cmpuint(c.commits, ==, 1); settle();
    g_assert_false(g_hash_table_contains(m.closed, active)); g_assert_true(g_hash_table_contains(m.closed, m.last_session));
  }
  m.mode = NORMAL; c.reject_commit = TRUE;
  mc_portal_shortcuts_replace(portal, bindings, "", commit, finished, &c); wait_count(&c.finished, 4);
  g_assert_false(c.success); settle(); g_assert_false(g_hash_table_contains(m.closed, active)); c.reject_commit = FALSE;
  // A pending session must never dispatch actions before its commit succeeds.
  m.mode = HOLD; guint bind_count = m.binds;
  mc_portal_shortcuts_replace(portal, bindings, "", commit, finished, &c); wait_count(&m.binds, bind_count + 1);
  g_assert_true(mc_portal_shortcuts_busy(portal));
  activation(&m, m.last_session, "record", TRUE); activation(&m, active, "stop", TRUE);
  wait_count(&c.actions[2], 1); g_assert_cmpuint(c.actions[1], ==, 0);
  guint old_finished = c.finished, old_states = c.states, old_commits = c.commits;
  mc_portal_shortcuts_close(portal); g_assert_cmpuint(c.finished, ==, old_finished + 1); g_assert_false(c.success);
  respond(&m, m.held_path, 0, m.held_results);
  g_dbus_method_invocation_return_value(m.held_call, g_variant_new("(o)", m.held_path));
  g_clear_object(&m.held_call); g_clear_pointer(&m.held_results, g_variant_unref); g_clear_pointer(&m.held_path, g_free);
  activation(&m, active, "record", TRUE); settle();
  g_assert_cmpuint(c.commits, ==, old_commits); g_assert_cmpuint(c.states, ==, old_states);
  g_assert_cmpuint(c.finished, ==, old_finished + 1); g_assert_cmpuint(c.actions[1], ==, 0);
  g_assert_true(g_hash_table_contains(m.closed, active)); g_assert_true(g_hash_table_contains(m.closed, m.last_session));
  // Service availability is checked before opening a session.
  m.mode = NORMAL; m.version = 0; portal = mc_portal_shortcuts_new(bus, descriptors, action, state, &c);
  guint creates = m.creates;
  mc_portal_shortcuts_replace(portal, bindings, "", commit, finished, &c); wait_count(&c.finished, old_finished + 2);
  g_assert_false(c.success); g_assert_cmpuint(m.creates, ==, creates);
  m.version = 1;
  mc_portal_shortcuts_replace(portal, bindings, "", commit, finished, &c); wait_count(&c.finished, old_finished + 3);
  g_assert_true(c.success); g_free(active); active = g_strdup(m.last_session);
  // The compositor can change or remove bindings independently. Display its
  // actual labels, and never dispatch an action which it has removed.
  GVariantBuilder changed, props;
  g_variant_builder_init(&changed, G_VARIANT_TYPE("a(sa{sv})"));
  g_variant_builder_init(&props, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&props, "{sv}", "trigger_description", g_variant_new_string("桌面改为 Super+9"));
  g_variant_builder_add(&changed, "(sa{sv})", "capture", &props);
  g_hash_table_replace(m.values, g_strdup(active), g_variant_ref_sink(g_variant_builder_end(&changed)));
  guint states = c.states;
  g_dbus_connection_emit_signal(m.bus, NULL, DESKTOP, GLOBAL, "ShortcutsChanged",
    g_variant_new("(o@a(sa{sv}))", active, g_variant_ref(g_hash_table_lookup(m.values, active))), NULL);
  wait_count(&c.states, states + 1); g_assert_cmpuint(m.lists, ==, 1);
  g_assert_cmpstr(c.labels[0], ==, "桌面改为 Super+9"); g_assert_null(c.labels[1]); g_assert_false(c.active);
  activation(&m, active, "record", TRUE); settle(); g_assert_cmpuint(c.actions[1], ==, 0);
  // Clearing the final binding is local: save first, then retire the session.
  // A failed save retains it, and neither path opens a new permission request.
  const MCShortcutBinding disabled[3] = {{0, 0}, {0, 0}, {0, 0}};
  creates = m.creates; guint binds = m.binds, finishes = c.finished;
  c.reject_commit = TRUE;
  mc_portal_shortcuts_replace(portal, disabled, "", commit, finished, &c);
  g_assert_cmpuint(c.finished, ==, finishes + 1); g_assert_false(c.success);
  settle(); g_assert_false(g_hash_table_contains(m.closed, active));
  c.reject_commit = FALSE;
  mc_portal_shortcuts_replace(portal, disabled, "", commit, finished, &c);
  g_assert_cmpuint(c.finished, ==, finishes + 2); g_assert_true(c.success); g_assert_false(c.active);
  settle(); g_assert_true(g_hash_table_contains(m.closed, active));
  g_assert_cmpuint(m.creates, ==, creates); g_assert_cmpuint(m.binds, ==, binds);
  g_assert_null(c.labels[0]); g_assert_null(c.labels[1]); g_assert_null(c.labels[2]);
  // Rebind, then verify external session invalidation.
  finishes = c.finished;
  mc_portal_shortcuts_replace(portal, bindings, "", commit, finished, &c); wait_count(&c.finished, finishes + 1);
  g_assert_true(c.success); g_free(active); active = g_strdup(m.last_session);
  states = c.states;
  g_dbus_connection_emit_signal(m.bus, NULL, active, SESSION, "Closed", g_variant_new("(@a{sv})", empty()), NULL);
  wait_count(&c.states, states + 1); g_assert_false(c.active);
  mc_portal_shortcuts_close(portal); settle();
  // Host teardown during a synchronous all-disabled commit still completes
  // the transaction exactly once, without a later callback into the host.
  portal = mc_portal_shortcuts_new(bus, descriptors, action, state, &c);
  c.close_on_commit = portal; finishes = c.finished; states = c.states;
  mc_portal_shortcuts_replace(portal, disabled, "", commit, finished, &c);
  g_assert_cmpuint(c.finished, ==, finishes + 1); g_assert_false(c.success);
  settle(); g_assert_cmpuint(c.finished, ==, finishes + 1); g_assert_cmpuint(c.states, ==, states);
  for (guint i = 0; i < m.registrations->len; i++) g_dbus_connection_unregister_object(m.bus, g_array_index(m.registrations, guint, i));
  g_array_unref(m.registrations); g_hash_table_unref(m.closed); g_hash_table_unref(m.values);
  g_dbus_node_info_unref(m.info); g_free(m.last_session); g_free(active);
  for (unsigned i = 0; i < 3; i++) g_free(c.labels[i]);
  g_dbus_connection_close_sync(bus, NULL, NULL); g_dbus_connection_close_sync(m.bus, NULL, NULL);
  g_object_unref(bus); g_object_unref(m.bus); g_test_dbus_down(test); g_object_unref(test);
  g_print("PASS portal shortcuts: private bus, early Response, actual labels, partial/cancel rollback, commit failure, pending actions, close/late cleanup, availability, changed/removed bindings, clear-all and session loss.\n");
  return 0;
}
