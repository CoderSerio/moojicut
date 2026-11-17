#include <gtk/gtk.h>
#include <libayatana-appindicator/app-indicator.h>
#include <glib/gstdio.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <X11/Xlib.h>
#include <gdk/gdkx.h>
#include "moonbit.h"
#include "plugins/feature/capture/linux/capture.h"
#include "plugins/feature/pin/linux/pinning.h"
#include "plugins/feature/recording/linux/recording.h"
#include "updates.h"
#include "platform/linux/input/global_shortcuts.h"
#include "bindings/c/tool_registry.h"

#ifndef MOOJICUT_VERSION
#define MOOJICUT_VERSION "development"
#endif

extern int32_t preview_core_check(void);
extern int32_t shortcut_validate(int32_t, int32_t, int32_t, int32_t, int32_t, int32_t);

typedef MCShortcutBinding Shortcut;
typedef struct {
  GtkApplication *application;
  AppIndicator *indicator;
  GtkWidget *window, *notebook, *status, *recorders[3], *dark_toggle, *pin_toggle, *pin_menu[3];
  GtkWidget *record_start_menu, *record_stop_menu;
  GtkWidget *shortcut_note, *shortcut_enable;
  GtkWidget *tool_settings;
  guint tool_settings_refresh;
  int tool_snapshot;
  char *tool_layout;
  MCGlobalShortcuts *global_shortcuts;
  char *shortcut_status, *shortcut_actual[3];
  gboolean shortcuts_pending, shortcut_keyboard_grabbed;
  Shortcut shortcuts[3];
  gboolean prefer_dark, system_dark, smoke, activated, core_ok, pin_enabled, pins_ready, quitting;
  int recording, exit_code;
  char *config_path, *smoke_dir, *icon_path;
} Host;

static Host host;
static const char *action_ids[] = { "capture", "record", "stop" };
static const char *action_labels[] = { "截图", "开始录屏", "停止录屏" };
static const Shortcut defaults[] = { { '1', 5 }, { '2', 5 }, { 'X', 5 } };

static void show_preferences(void);
static void cancel_recording(void);
static void menu_capture(GtkWidget *widget, gpointer data);
static void menu_record(GtkWidget *widget, gpointer data);
static void menu_stop(GtkWidget *widget, gpointer data);
static gboolean save_settings(void);
static void global_shortcut_action(unsigned index, gpointer data);
static void global_shortcut_state(gboolean active, const char *message, const char *const labels[3], gpointer data);
static void refresh_tool_settings(void);
static void queue_tool_settings_refresh(void);
static void cancel_tool_settings_refresh(void);
static void sync_pin_feature(void);
static void pin_feature_changed(GtkToggleButton *button, gpointer data);
static gboolean publish_tools(int candidate);

static moonbit_string_t core_string(const char *text) {
  glong length = 0;
  gunichar2 *utf16 = g_utf8_to_utf16(text ? text : "", -1, NULL, &length, NULL);
  moonbit_string_t result = moonbit_make_string_raw((int32_t)length);
  if (length) memcpy(result, utf16, (gsize)length * sizeof(gunichar2));
  g_free(utf16); return result;
}
static char *core_text(moonbit_string_t value) {
  char *result = g_utf16_to_utf8((gunichar2 *)value, Moonbit_array_length(value), NULL, NULL, NULL);
  moonbit_decref(value); return result ? result : g_strdup("");
}
static char *tool_text(int snapshot, int index, int key) {
  return core_text(tool_registry_snapshot_text(snapshot, MC_TOOL_GROUP_SCREENSHOT, index, key));
}
static int open_tools(const char *layout) {
  moonbit_string_t input = core_string(layout);
  moonbit_string_t result = tool_registry_normalize(input);
  int snapshot = tool_registry_snapshot_open(result, MC_TOOL_CAP_COMMANDS);
  moonbit_decref(result); moonbit_decref(input); return snapshot;
}
static int tool_action_index(int snapshot, const char *action) {
  int count = tool_registry_snapshot_count(snapshot, MC_TOOL_GROUP_SCREENSHOT);
  for (int index = 0; index < count; index++) {
    char *current = tool_text(snapshot, index, MC_TOOL_ACTION);
    gboolean equal = !strcmp(current, action); g_free(current);
    if (equal) return index;
  }
  return -1;
}
static int pin_candidate(int snapshot, gboolean enabled) {
  int index = tool_action_index(snapshot, "pin");
  if (index < 0) return 0;
  char *text = tool_text(snapshot, index, MC_TOOL_ID);
  moonbit_string_t id = core_string(text); g_free(text);
  int candidate = tool_registry_snapshot_set_enabled(snapshot, id, enabled ? 1 : 0);
  moonbit_decref(id); return candidate;
}
static void read_pin_preference(void) {
  int index = tool_action_index(host.tool_snapshot, "pin");
  host.pin_enabled = index >= 0 && tool_registry_snapshot_value(host.tool_snapshot,
    MC_TOOL_GROUP_SCREENSHOT, index, MC_TOOL_ENABLED) == 1;
}

static int validate_shortcut(int index, Shortcut value) {
  Shortcut a = host.shortcuts[(index + 1) % 3];
  Shortcut b = host.shortcuts[(index + 2) % 3];
  return shortcut_validate(value.key, value.mods, a.key, a.mods, b.key, b.mods);
}

static void set_status(const char *message) {
  if (host.status) gtk_label_set_text(GTK_LABEL(host.status), message);
}

static char *shortcut_label(Shortcut value) {
  if (!value.key) return g_strdup("未设置");
  GString *label = g_string_new(NULL);
  if (value.mods & 1) g_string_append(label, "Ctrl + ");
  if (value.mods & 2) g_string_append(label, "Alt + ");
  if (value.mods & 4) g_string_append(label, "Shift + ");
  if (value.mods & 8) g_string_append(label, "Super + ");
  if (value.key >= 256) g_string_append_printf(label, "F%d", value.key - 255);
  else g_string_append_c(label, (char)value.key);
  return g_string_free(label, FALSE);
}

static void refresh_shortcuts(void) {
  for (int i = 0; i < 3; i++) {
    if (!host.recorders[i]) continue;
    char *label = host.shortcut_actual[i] ? g_strdup(host.shortcut_actual[i]) : shortcut_label(host.shortcuts[i]);
    gtk_button_set_label(GTK_BUTTON(host.recorders[i]), i == host.recording ? "按下快捷键…" : label);
    gtk_widget_set_sensitive(host.recorders[i], !host.shortcuts_pending);
    g_free(label);
  }
}

typedef struct { Shortcut candidate[3]; gboolean persist, inside_call, finished, success; } ShortcutChange;
/* The smoke fixture can suspend this external authorization boundary without
 * contacting the user's portal. All validation and host state remain real. */
static void (*request_shortcuts)(MCGlobalShortcuts *, const MCShortcutBinding[3], const char *,
    MCShortcutCommit, MCShortcutFinished, gpointer) = mc_global_shortcuts_replace;
static gboolean commit_shortcuts(const MCShortcutBinding values[3], const char *const labels[3], gpointer data) {
  (void)labels;
  ShortcutChange *change = data;
  if (host.quitting) return FALSE;
  Shortcut previous[3]; memcpy(previous, host.shortcuts, sizeof(previous));
  memcpy(host.shortcuts, values, sizeof(host.shortcuts));
  if (change->persist && !save_settings()) {
    memcpy(host.shortcuts, previous, sizeof(previous)); return FALSE;
  }
  cancel_recording();
  return TRUE;
}
static void shortcut_change_finished(gboolean success, const char *message, gpointer data) {
  ShortcutChange *change = data;
  change->finished = TRUE; change->success = success;
  host.shortcuts_pending = FALSE;
  if (!host.quitting) {
    g_free(host.shortcut_status); host.shortcut_status = g_strdup(message);
    if (host.shortcut_note) gtk_label_set_text(GTK_LABEL(host.shortcut_note), message);
    set_status(message); refresh_shortcuts();
  }
  if (!change->inside_call) g_free(change);
}
static gboolean replace_shortcuts(const Shortcut candidate[3], gboolean persist) {
  if (host.shortcuts_pending || mc_global_shortcuts_busy(host.global_shortcuts)) {
    set_status("请等待当前快捷键申请完成。"); return FALSE;
  }
  /* A valid candidate is no longer keyboard input. Waiting for portal consent
   * must not leave recording>=0 and swallow the previous session's stop key. */
  cancel_recording();
  ShortcutChange *change = g_new0(ShortcutChange, 1);
  memcpy(change->candidate, candidate, sizeof(change->candidate));
  change->persist = persist; change->inside_call = TRUE;
  host.shortcuts_pending = TRUE; refresh_shortcuts();
  char *parent = NULL;
  if (host.window && gtk_widget_get_realized(host.window) && GDK_IS_X11_DISPLAY(gtk_widget_get_display(host.window)))
    parent = g_strdup_printf("x11:%lx", gdk_x11_window_get_xid(gtk_widget_get_window(host.window)));
  request_shortcuts(host.global_shortcuts, change->candidate, parent ? parent : "",
    commit_shortcuts, shortcut_change_finished, change);
  g_free(parent);
  gboolean accepted = !change->finished || change->success;
  change->inside_call = FALSE;
  if (change->finished) g_free(change);
  return accepted;
}

static gboolean save_settings_with_tools(const char *layout) {
  GKeyFile *settings = g_key_file_new();
  g_key_file_set_boolean(settings, "General", "prefer-dark", host.prefer_dark);
  if (layout) g_key_file_set_string(settings, "Tools", "layout", layout);
  for (int i = 0; i < 3; i++) {
    int values[] = { host.shortcuts[i].key, host.shortcuts[i].mods };
    g_key_file_set_integer_list(settings, "Shortcuts", action_ids[i], values, 2);
  }
  gsize length = 0;
  char *data = g_key_file_to_data(settings, &length, NULL);
  char *directory = g_path_get_dirname(host.config_path);
  GError *error = NULL;
  gboolean ok = g_mkdir_with_parents(directory, 0700) == 0;
  if (ok) ok = g_file_set_contents(host.config_path, data, (gssize)length, &error);
  if (ok) g_chmod(host.config_path, 0600);
  if (!ok) {
    g_printerr("Cannot save settings: %s\n", error ? error->message : "configuration directory is not writable");
    set_status("设置未保存，请检查配置目录的写入权限。");
  }
  g_clear_error(&error);
  g_free(directory);
  g_free(data);
  g_key_file_unref(settings);
  return ok;
}
static gboolean save_settings(void) { return save_settings_with_tools(host.tool_layout); }

static void load_settings(void) {
  memcpy(host.shortcuts, defaults, sizeof(defaults));
  host.prefer_dark = FALSE;
  gboolean legacy_pin_enabled = TRUE;
  GKeyFile *settings = g_key_file_new();
  char *saved_tools = NULL;
  if (g_key_file_load_from_file(settings, host.config_path, G_KEY_FILE_NONE, NULL)) {
    saved_tools = g_key_file_get_string(settings, "Tools", "layout", NULL);
    host.prefer_dark = g_key_file_get_boolean(settings, "General", "prefer-dark", NULL);
    if (g_key_file_has_key(settings, "Features", "pin-enabled", NULL))
      legacy_pin_enabled = g_key_file_get_boolean(settings, "Features", "pin-enabled", NULL);
    for (int i = 0; i < 3; i++) {
      gsize count = 0;
      int *value = g_key_file_get_integer_list(settings, "Shortcuts", action_ids[i], &count, NULL);
      if (value && count == 2) host.shortcuts[i] = (Shortcut){ value[0], value[1] };
      g_free(value);
    }
    for (int i = 0; i < 3; i++) {
      if (validate_shortcut(i, host.shortcuts[i]) != 0) {
        memcpy(host.shortcuts, defaults, sizeof(defaults));
        break;
      }
    }
  }
  int snapshot = open_tools(saved_tools ? saved_tools : "");
  if (snapshot <= 0) snapshot = open_tools("");
  /* Import the former feature flag only for configurations without a tool
   * layout. Once present, the saved contribution preference is authoritative. */
  if ((!saved_tools || !*saved_tools) && !legacy_pin_enabled && snapshot > 0) {
    int migrated = pin_candidate(snapshot, FALSE);
    if (migrated > 0) { tool_registry_snapshot_close(snapshot); snapshot = migrated; }
  }
  g_free(saved_tools);
  if (snapshot > 0) {
    int old = host.tool_snapshot; host.tool_snapshot = snapshot;
    g_free(host.tool_layout); host.tool_layout = core_text(tool_registry_snapshot_layout(snapshot));
    read_pin_preference();
    mc_linux_capture_publish_tools(snapshot);
    sync_pin_feature();
    if (old > 0) tool_registry_snapshot_close(old);
    refresh_tool_settings();
  }
  g_key_file_unref(settings);
}

static gboolean update_shortcut(int index, Shortcut value) {
  int result = validate_shortcut(index, value);
  if (result) {
    set_status(result == 1 ? "字母或数字请搭配 Ctrl、Alt 或 Super。" :
      result == 2 ? "这个组合已用于另一个操作，请换一个。" : "支持字母、数字及 F1–F24 功能键。");
    return FALSE;
  }
  Shortcut candidate[3]; memcpy(candidate, host.shortcuts, sizeof(candidate));
  candidate[index] = value;
  return replace_shortcuts(candidate, TRUE);
}

static void cancel_recording(void) {
  if (host.shortcut_keyboard_grabbed) {
    gdk_seat_ungrab(gdk_display_get_default_seat(gdk_display_get_default()));
    host.shortcut_keyboard_grabbed = FALSE;
  }
  host.recording = -1;
  refresh_shortcuts();
}

static void begin_recording(GtkButton *button, gpointer data) {
  (void)button;
  if (host.shortcuts_pending) { set_status("请等待当前快捷键申请完成。"); return; }
  cancel_recording();
  if (host.window && GDK_IS_X11_DISPLAY(gtk_widget_get_display(host.window))) {
    GdkGrabStatus result = gdk_seat_grab(gdk_display_get_default_seat(gtk_widget_get_display(host.window)),
      gtk_widget_get_window(host.window), GDK_SEAT_CAPABILITY_KEYBOARD, TRUE, NULL, NULL, NULL, NULL);
    if (result != GDK_GRAB_SUCCESS) { set_status("无法录入快捷键，请先结束其他输入操作。"); return; }
    host.shortcut_keyboard_grabbed = TRUE;
  }
  host.recording = GPOINTER_TO_INT(data);
  refresh_shortcuts();
  set_status("按下组合键；Esc 取消，Delete 清除。");
}

static void clear_shortcut(GtkButton *button, gpointer data) {
  (void)button;
  update_shortcut(GPOINTER_TO_INT(data), (Shortcut){ 0, 0 });
}

static void reset_shortcuts(GtkButton *button, gpointer data) {
  (void)button; (void)data;
  replace_shortcuts(defaults, TRUE);
}

static void enable_shortcuts(GtkButton *button, gpointer data) {
  (void)button; (void)data;
  replace_shortcuts(host.shortcuts, TRUE);
}

static gboolean capture_key(GtkWidget *widget, GdkEventKey *event, gpointer data) {
  (void)data;
  if (host.recording < 0) return FALSE;
  if (event->keyval == GDK_KEY_Escape || event->keyval == GDK_KEY_Tab || event->keyval == GDK_KEY_ISO_Left_Tab) {
    cancel_recording();
    set_status("已取消快捷键录入。");
    return event->keyval == GDK_KEY_Escape;
  }
  if (event->keyval == GDK_KEY_BackSpace || event->keyval == GDK_KEY_Delete) {
    update_shortcut(host.recording, (Shortcut){ 0, 0 });
    return TRUE;
  }
  if ((event->keyval >= GDK_KEY_Shift_L && event->keyval <= GDK_KEY_Hyper_R) ||
      event->keyval == GDK_KEY_ISO_Level3_Shift || event->keyval == GDK_KEY_Mode_switch) return TRUE;
  guint keyval = event->keyval;
  GdkKeymap *keymap = gdk_keymap_get_for_display(gtk_widget_get_display(widget));
  GdkModifierType base_state = (GdkModifierType)(event->state &
    ~(GDK_SHIFT_MASK | GDK_LOCK_MASK | GDK_CONTROL_MASK | GDK_MOD1_MASK | GDK_SUPER_MASK | GDK_META_MASK));
  gdk_keymap_translate_keyboard_state(keymap, event->hardware_keycode, base_state,
    event->group, &keyval, NULL, NULL, NULL);
  keyval = gdk_keyval_to_upper(keyval);
  int key = keyval >= GDK_KEY_F1 && keyval <= GDK_KEY_F24 ? (int)(keyval - GDK_KEY_F1 + 256) :
    ((keyval >= 'A' && keyval <= 'Z') || (keyval >= '0' && keyval <= '9')) ? (int)keyval : -1;
  int mods = ((event->state & GDK_CONTROL_MASK) ? 1 : 0) | ((event->state & GDK_MOD1_MASK) ? 2 : 0) |
    ((event->state & GDK_SHIFT_MASK) ? 4 : 0) | ((event->state & (GDK_SUPER_MASK | GDK_META_MASK)) ? 8 : 0);
  update_shortcut(host.recording, (Shortcut){ key, mods });
  return TRUE;
}

static gboolean focus_out(GtkWidget *widget, GdkEventFocus *event, gpointer data) {
  (void)widget; (void)event; (void)data;
  cancel_recording();
  return FALSE;
}

static void switch_page(GtkNotebook *notebook, GtkWidget *page, guint index, gpointer data) {
  (void)notebook; (void)page; (void)index; (void)data;
  cancel_recording();
}

static void appearance_changed(GtkToggleButton *button, gpointer data) {
  (void)data;
  gboolean previous = host.prefer_dark;
  host.prefer_dark = gtk_toggle_button_get_active(button);
  if (!save_settings()) {
    host.prefer_dark = previous;
    g_signal_handlers_block_by_func(button, appearance_changed, NULL);
    gtk_toggle_button_set_active(button, previous);
    g_signal_handlers_unblock_by_func(button, appearance_changed, NULL);
    return;
  }
  g_object_set(gtk_settings_get_default(), "gtk-application-prefer-dark-theme",
    host.prefer_dark || host.system_dark, NULL);
  set_status("外观偏好已保存。");
}
static void sync_pin_feature(void) {
  if (host.pins_ready) mc_linux_pins_set_enabled(host.pin_enabled);
  if (host.pin_toggle) {
    g_signal_handlers_block_by_func(host.pin_toggle, pin_feature_changed, NULL);
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(host.pin_toggle), host.pin_enabled);
    g_signal_handlers_unblock_by_func(host.pin_toggle, pin_feature_changed, NULL);
  }
  mc_linux_capture_refresh_capabilities();
  for (int i = 0; i < 3; i++)
    if (host.pin_menu[i]) gtk_widget_set_sensitive(host.pin_menu[i], host.pin_enabled);
}
static void pin_feature_changed(GtkToggleButton *button, gpointer data) {
  (void)data;
  /* The general switch is another view of the same saved contribution, not a
   * second policy. Persist before disabling, which closes existing pins. */
  if (publish_tools(pin_candidate(host.tool_snapshot, gtk_toggle_button_get_active(button))))
    set_status(host.pin_enabled ? "贴图已启用。" : "贴图已关闭，当前贴图与全局按键已释放；按键配置保留。");
  else sync_pin_feature();
}

static GtkWidget *label(const char *text, gboolean secondary) {
  GtkWidget *widget = gtk_label_new(text);
  gtk_label_set_xalign(GTK_LABEL(widget), 0);
  gtk_label_set_line_wrap(GTK_LABEL(widget), TRUE);
  gtk_label_set_max_width_chars(GTK_LABEL(widget), 60);
  if (secondary) gtk_style_context_add_class(gtk_widget_get_style_context(widget), "dim-label");
  return widget;
}

static GtkWidget *page(void) {
  GtkWidget *widget = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16);
  gtk_container_set_border_width(GTK_CONTAINER(widget), 24);
  return widget;
}

static gboolean publish_tools(int candidate) {
  if (candidate <= 0) {
    set_status("工具配置无效，原设置未改动。"); queue_tool_settings_refresh(); return FALSE;
  }
  const char *reason = NULL;
  if (!mc_linux_capture_preflight_tools(candidate, &reason)) {
    tool_registry_snapshot_close(candidate);
    set_status(reason ? reason : "请先完成当前截图输入再调整工具。");
    queue_tool_settings_refresh(); return FALSE;
  }
  char *layout = core_text(tool_registry_snapshot_layout(candidate));
  if (!*layout || !save_settings_with_tools(layout)) {
    g_free(layout); tool_registry_snapshot_close(candidate);
    queue_tool_settings_refresh(); return FALSE;
  }
  int previous = host.tool_snapshot;
  host.tool_snapshot = candidate;
  g_free(host.tool_layout); host.tool_layout = layout;
  read_pin_preference();
  mc_linux_capture_publish_tools(candidate);
  sync_pin_feature();
  if (previous > 0) tool_registry_snapshot_close(previous);
  queue_tool_settings_refresh(); set_status("工具设置已保存并应用。"); return TRUE;
}
static void tool_enabled(GtkToggleButton *button, gpointer data) {
  (void)data;
  moonbit_string_t id = core_string(g_object_get_data(G_OBJECT(button), "tool-id"));
  int candidate = tool_registry_snapshot_set_enabled(host.tool_snapshot, id,
    gtk_toggle_button_get_active(button) ? 1 : 0);
  moonbit_decref(id); publish_tools(candidate);
}
static void move_tool(GtkButton *button, gpointer data) {
  int direction = GPOINTER_TO_INT(data), slot = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(button), "tool-slot"));
  const char *wanted = g_object_get_data(G_OBJECT(button), "tool-id");
  GPtrArray *ids = g_ptr_array_new_with_free_func(g_free); int current = -1;
  int count = tool_registry_snapshot_count(host.tool_snapshot, MC_TOOL_GROUP_SCREENSHOT);
  for (int i = 0; i < count; i++) if (tool_registry_snapshot_value(host.tool_snapshot, MC_TOOL_GROUP_SCREENSHOT, i, MC_TOOL_SLOT) == slot) {
    char *id = tool_text(host.tool_snapshot, i, MC_TOOL_ID);
    if (!g_strcmp0(id, wanted)) current = (int)ids->len;
    g_ptr_array_add(ids, id);
  }
  if (current < 0 || current + direction < 0 || current + direction >= (int)ids->len) { g_ptr_array_unref(ids); return; }
  const char *before = direction < 0 ? g_ptr_array_index(ids, current - 1) :
    current + 2 < (int)ids->len ? g_ptr_array_index(ids, current + 2) : "";
  moonbit_string_t id = core_string(wanted), next = core_string(before);
  int candidate = tool_registry_snapshot_move(host.tool_snapshot, id, next);
  moonbit_decref(id); moonbit_decref(next); g_ptr_array_unref(ids);
  publish_tools(candidate);
}
static void cancel_tool_settings_refresh(void) {
  guint pending = host.tool_settings_refresh;
  host.tool_settings_refresh = 0;
  if (pending) g_source_remove(pending);
}
static gboolean refresh_tool_settings_idle(gpointer data) {
  host.tool_settings_refresh = 0;
  /* The retained container cannot be reused by a subsequently opened window.
   * This idle only renders current state; it never replays a settings change. */
  if (!host.quitting && host.tool_settings == data &&
      !gtk_widget_in_destruction(GTK_WIDGET(data))) refresh_tool_settings();
  return G_SOURCE_REMOVE;
}
static void queue_tool_settings_refresh(void) {
  if (!host.tool_settings || host.tool_settings_refresh || host.quitting) return;
  /* GtkToggleButton notifies active after its toggled/clicked callbacks return.
   * Rebuilding rows inside those callbacks can free the notifying button. */
  host.tool_settings_refresh = g_idle_add_full(G_PRIORITY_DEFAULT_IDLE,
    refresh_tool_settings_idle, g_object_ref(host.tool_settings), g_object_unref);
}
static void refresh_tool_settings(void) {
  cancel_tool_settings_refresh();
  if (!host.tool_settings) return;
  GList *children = gtk_container_get_children(GTK_CONTAINER(host.tool_settings));
  for (GList *item = children; item; item = item->next) gtk_widget_destroy(item->data);
  g_list_free(children);
  int count = tool_registry_snapshot_count(host.tool_snapshot, MC_TOOL_GROUP_SCREENSHOT);
  for (int slot = MC_TOOL_SLOT_TOOLS; slot <= MC_TOOL_SLOT_FINISH; slot++) {
    GtkWidget *heading = label(slot == MC_TOOL_SLOT_TOOLS ? "截图工具" : "完成操作", FALSE);
    gtk_box_pack_start(GTK_BOX(host.tool_settings), heading, FALSE, FALSE, 0);
    int rows = 0;
    for (int i = 0; i < count; i++) if (tool_registry_snapshot_value(host.tool_snapshot, MC_TOOL_GROUP_SCREENSHOT, i, MC_TOOL_SLOT) == slot) rows++;
    int position = 0;
    for (int i = 0; i < count; i++) {
      if (tool_registry_snapshot_value(host.tool_snapshot, MC_TOOL_GROUP_SCREENSHOT, i, MC_TOOL_SLOT) != slot) continue;
      char *id = tool_text(host.tool_snapshot, i, MC_TOOL_ID), *title = tool_text(host.tool_snapshot, i, MC_TOOL_TITLE);
      char *reason = tool_text(host.tool_snapshot, i, MC_TOOL_UNAVAILABLE_REASON);
      GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
      GtkWidget *enabled = gtk_check_button_new_with_label(title);
      gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(enabled), tool_registry_snapshot_value(host.tool_snapshot, MC_TOOL_GROUP_SCREENSHOT, i, MC_TOOL_ENABLED) == 1);
      g_object_set_data_full(G_OBJECT(enabled), "tool-id", g_strdup(id), g_free);
      g_signal_connect(enabled, "toggled", G_CALLBACK(tool_enabled), NULL);
      gtk_box_pack_start(GTK_BOX(row), enabled, TRUE, TRUE, 0);
      if (tool_registry_snapshot_value(host.tool_snapshot, MC_TOOL_GROUP_SCREENSHOT, i, MC_TOOL_AVAILABLE) != 1) {
        GtkWidget *unavailable = label(*reason ? reason : "当前后端不可用", TRUE);
        gtk_box_pack_start(GTK_BOX(row), unavailable, FALSE, FALSE, 0);
        gtk_widget_set_tooltip_text(enabled, *reason ? reason : "当前后端不可用");
      }
      for (int direction = -1; direction <= 1; direction += 2) {
        GtkWidget *button = gtk_button_new_with_label(direction < 0 ? "↑" : "↓");
        gtk_widget_set_tooltip_text(button, direction < 0 ? "上移" : "下移");
        gtk_widget_set_sensitive(button, direction < 0 ? position > 0 : position + 1 < rows);
        g_object_set_data_full(G_OBJECT(button), "tool-id", g_strdup(id), g_free);
        g_object_set_data(G_OBJECT(button), "tool-slot", GINT_TO_POINTER(slot));
        g_signal_connect(button, "clicked", G_CALLBACK(move_tool), GINT_TO_POINTER(direction));
        gtk_box_pack_start(GTK_BOX(row), button, FALSE, FALSE, 0);
      }
      gtk_box_pack_start(GTK_BOX(host.tool_settings), row, FALSE, FALSE, 0);
      g_free(id); g_free(title); g_free(reason); position++;
    }
  }
  gtk_widget_show_all(host.tool_settings);
}

static void window_destroyed(GtkWidget *widget, gpointer data) {
  (void)widget; (void)data;
  cancel_tool_settings_refresh();
  host.window = host.notebook = host.status = host.dark_toggle = host.pin_toggle = NULL;
  host.shortcut_note = host.shortcut_enable = NULL;
  host.tool_settings = NULL;
  memset(host.recorders, 0, sizeof(host.recorders));
  cancel_recording();
}

static void quit_app(GtkWidget *widget, gpointer data) {
  (void)widget; (void)data;
  if (host.quitting) return;
  host.quitting = TRUE;
  MCGlobalShortcuts *shortcuts = host.global_shortcuts; host.global_shortcuts = NULL;
  mc_global_shortcuts_close(shortcuts);
  cancel_recording();
  mc_linux_recording_shutdown();
  mc_linux_capture_close();
  mc_linux_pins_set_enabled(FALSE);
  if (host.window) gtk_widget_destroy(host.window);
  mc_linux_updates_cancel_all();
  if (host.indicator) app_indicator_set_status(host.indicator, APP_INDICATOR_STATUS_PASSIVE);
  /* Download tasks hold the application until cancelled workers finish removing
   * partial files. Releasing startup's hold leaves the GTK loop responsive. */
  g_application_release(G_APPLICATION(host.application));
}

static void show_preferences(void) {
  if (host.window) {
    gtk_window_present(GTK_WINDOW(host.window));
    return;
  }
  host.window = gtk_application_window_new(host.application);
  gtk_window_set_title(GTK_WINDOW(host.window), "Mooji Cut · 设置");
  gtk_window_set_default_size(GTK_WINDOW(host.window), 580, 420);
  gtk_window_set_position(GTK_WINDOW(host.window), GTK_WIN_POS_CENTER);
  gtk_window_set_icon_from_file(GTK_WINDOW(host.window), host.icon_path, NULL);
  g_signal_connect(host.window, "destroy", G_CALLBACK(window_destroyed), NULL);
  g_signal_connect(host.window, "key-press-event", G_CALLBACK(capture_key), NULL);
  g_signal_connect(host.window, "focus-out-event", G_CALLBACK(focus_out), NULL);
  GtkWidget *layout = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
  gtk_container_set_border_width(GTK_CONTAINER(layout), 16);
  gtk_container_add(GTK_CONTAINER(host.window), layout);
  host.notebook = gtk_notebook_new();
  gtk_box_pack_start(GTK_BOX(layout), host.notebook, TRUE, TRUE, 0);
  g_signal_connect(host.notebook, "switch-page", G_CALLBACK(switch_page), NULL);

  GtkWidget *general = page();
  gtk_box_pack_start(GTK_BOX(general), label("这一幕，我截下了。", FALSE), FALSE, FALSE, 0);
  GtkWidget *capture_button = gtk_button_new_with_label("截图并标注…");
  gtk_widget_set_halign(capture_button, GTK_ALIGN_START);
  g_signal_connect(capture_button, "clicked", G_CALLBACK(menu_capture), NULL);
  gtk_box_pack_start(GTK_BOX(general), capture_button, FALSE, FALSE, 0);
  GtkWidget *record_button = gtk_button_new_with_label("开始录屏…");
  gtk_widget_set_halign(record_button, GTK_ALIGN_START);
  g_signal_connect(record_button, "clicked", G_CALLBACK(menu_record), NULL);
  gtk_box_pack_start(GTK_BOX(general), record_button, FALSE, FALSE, 0);
  GtkWidget *stop_button = gtk_button_new_with_label("停止录屏并保存");
  gtk_widget_set_halign(stop_button, GTK_ALIGN_START);
  g_signal_connect(stop_button, "clicked", G_CALLBACK(menu_stop), NULL);
  gtk_box_pack_start(GTK_BOX(general), stop_button, FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(general), label("X11 支持区域/整个屏幕；Wayland 由系统选择显示器或窗口。当前静音录制，保存为 WebM；开始后可从托盘停止。", TRUE), FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(general), label("关闭设置后，Mooji Cut 继续在托盘中待命。\n从托盘菜单打开设置，或选择退出。", TRUE), FALSE, FALSE, 0);
  host.dark_toggle = gtk_check_button_new_with_label("偏好深色外观");
  gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(host.dark_toggle), host.prefer_dark);
  g_signal_connect(host.dark_toggle, "toggled", G_CALLBACK(appearance_changed), NULL);
  gtk_box_pack_start(GTK_BOX(general), host.dark_toggle, FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(general), label("使用桌面的 GTK 主题；深色外观需要主题支持。", TRUE), FALSE, FALSE, 0);
  host.pin_toggle = gtk_check_button_new_with_label("启用贴图");
  gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(host.pin_toggle), host.pin_enabled);
  g_signal_connect(host.pin_toggle, "toggled", G_CALLBACK(pin_feature_changed), NULL);
  gtk_box_pack_start(GTK_BOX(general), host.pin_toggle, FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(general), label("关闭时会关闭所有当前贴图并释放贴图全局按键；按键配置保留，重新启用后可继续使用。", TRUE), FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(general), label("如果桌面未显示托盘图标，重新运行启动脚本即可打开设置。GNOME 桌面可能需要 AppIndicator 扩展。", TRUE), FALSE, FALSE, 0);
  gtk_notebook_append_page(GTK_NOTEBOOK(host.notebook), general, gtk_label_new("通用"));

  GtkWidget *shortcuts = page();
  GtkWidget *grid = gtk_grid_new();
  gtk_grid_set_row_spacing(GTK_GRID(grid), 12);
  gtk_grid_set_column_spacing(GTK_GRID(grid), 12);
  for (int i = 0; i < 3; i++) {
    gtk_grid_attach(GTK_GRID(grid), label(action_labels[i], FALSE), 0, i, 1, 1);
    host.recorders[i] = gtk_button_new();
    gtk_widget_set_hexpand(host.recorders[i], TRUE);
    gtk_widget_set_size_request(host.recorders[i], 250, -1);
    gtk_widget_set_tooltip_text(host.recorders[i], action_labels[i]);
    g_signal_connect(host.recorders[i], "clicked", G_CALLBACK(begin_recording), GINT_TO_POINTER(i));
    gtk_grid_attach(GTK_GRID(grid), host.recorders[i], 1, i, 1, 1);
    GtkWidget *clear = gtk_button_new_with_label("清除");
    g_signal_connect(clear, "clicked", G_CALLBACK(clear_shortcut), GINT_TO_POINTER(i));
    gtk_grid_attach(GTK_GRID(grid), clear, 2, i, 1, 1);
  }
  gtk_box_pack_start(GTK_BOX(shortcuts), grid, FALSE, FALSE, 0);
  GtkWidget *reset = gtk_button_new_with_label("恢复默认");
  gtk_widget_set_halign(reset, GTK_ALIGN_END);
  g_signal_connect(reset, "clicked", G_CALLBACK(reset_shortcuts), NULL);
  gtk_box_pack_start(GTK_BOX(shortcuts), reset, FALSE, FALSE, 0);
  host.shortcut_enable = gtk_button_new_with_label(mc_global_shortcuts_is_portal(host.global_shortcuts) ?
    "通过系统门户启用 / 重新绑定…" : "重新注册全局快捷键");
  gtk_widget_set_halign(host.shortcut_enable, GTK_ALIGN_START);
  g_signal_connect(host.shortcut_enable, "clicked", G_CALLBACK(enable_shortcuts), NULL);
  gtk_box_pack_start(GTK_BOX(shortcuts), host.shortcut_enable, FALSE, FALSE, 0);
  host.shortcut_note = label(host.shortcut_status ? host.shortcut_status : "正在准备全局快捷键…", TRUE);
  gtk_box_pack_start(GTK_BOX(shortcuts), host.shortcut_note, FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(shortcuts), label("注册成功后才保存配置。X11 会检查其他应用和贴图按键的冲突；Wayland 的实际组合由系统门户确认，未提供此门户的桌面请使用托盘。", TRUE), FALSE, FALSE, 0);
  gtk_notebook_append_page(GTK_NOTEBOOK(host.notebook), shortcuts, gtk_label_new("快捷键"));
  gtk_notebook_append_page(GTK_NOTEBOOK(host.notebook), mc_linux_pin_preferences(), gtk_label_new("贴图按键"));
  GtkWidget *tools = page();
  gtk_box_pack_start(GTK_BOX(tools), label("工具与完成操作分别排序。关闭标注工具不会删除已有标注；关闭贴图会关闭现有贴图。未接入的能力显示不可用。", TRUE), FALSE, FALSE, 0);
  GtkWidget *tool_scroll = gtk_scrolled_window_new(NULL, NULL);
  gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(tool_scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  host.tool_settings = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
  gtk_container_add(GTK_CONTAINER(tool_scroll), host.tool_settings);
  gtk_box_pack_start(GTK_BOX(tools), tool_scroll, TRUE, TRUE, 0);
  refresh_tool_settings();
  gtk_notebook_append_page(GTK_NOTEBOOK(host.notebook), tools, gtk_label_new("截图工具"));
  gtk_notebook_append_page(GTK_NOTEBOOK(host.notebook), mc_linux_update_preferences(), gtk_label_new("更新"));

  GtkWidget *about = page();
  GdkPixbuf *pixbuf = gdk_pixbuf_new_from_file_at_scale(host.icon_path, 72, 72, TRUE, NULL);
  if (pixbuf) {
    GtkWidget *icon = gtk_image_new_from_pixbuf(pixbuf);
    gtk_widget_set_halign(icon, GTK_ALIGN_START);
    gtk_box_pack_start(GTK_BOX(about), icon, FALSE, FALSE, 0);
    g_object_unref(pixbuf);
  }
  gtk_box_pack_start(GTK_BOX(about), label("Mooji Cut  " MOOJICUT_VERSION, FALSE), FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(about), label("以 MoonBit 为核心的本地截图与录屏工具。", FALSE), FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(about), label("Linux 原生预览版\n截图后原地标注、编辑文字、确认复制或固定贴图。X11 保留冻结桌面；Wayland 由系统门户提供截图，编辑位置与贴图置顶由桌面决定。录屏支持静音 WebM，录后编辑尚未接入。", TRUE), FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(about), label(host.core_ok ? "MoonBit native 核心已连接" : "MoonBit 核心检查失败", TRUE), FALSE, FALSE, 0);
  gtk_notebook_append_page(GTK_NOTEBOOK(host.notebook), about, gtk_label_new("关于"));

  host.status = label("截图编辑后复制到剪贴板。设置保存在本机。", TRUE);
  gtk_box_pack_start(GTK_BOX(layout), host.status, FALSE, FALSE, 0);
  GtkWidget *quit = gtk_button_new_with_label("退出 Mooji Cut");
  gtk_widget_set_halign(quit, GTK_ALIGN_END);
  g_signal_connect(quit, "clicked", G_CALLBACK(quit_app), NULL);
  gtk_box_pack_start(GTK_BOX(layout), quit, FALSE, FALSE, 0);
  refresh_shortcuts();
  gtk_widget_show_all(host.window);
  gtk_window_present(GTK_WINDOW(host.window));
}

static void menu_preferences(GtkWidget *widget, gpointer data) {
  (void)widget; (void)data;
  show_preferences();
}

static void capture_closed(gpointer data) {
  (void)data;
  mc_linux_pins_hide(FALSE);
}
static void pin_capture_result(GdkPixbuf *image, const GdkRectangle *bounds, gpointer data) {
  (void)data;
  if (host.pin_enabled) mc_linux_pin_image_at(image, bounds);
}
static gboolean can_pin_capture(gpointer data) { (void)data; return mc_linux_pins_enabled(); }
static const MCLinuxCaptureHost capture_host = {pin_capture_result, capture_closed, NULL, can_pin_capture};

static gboolean begin_capture(gpointer data) {
  (void)data;
  if (host.quitting || mc_linux_recording_busy()) return G_SOURCE_REMOVE;
  mc_linux_capture_start(host.application, &capture_host);
  return G_SOURCE_REMOVE;
}

static void menu_capture(GtkWidget *widget, gpointer data) {
  (void)widget; (void)data;
  if (mc_linux_recording_busy()) { set_status("请先停止录屏并等待保存完成。"); return; }
  cancel_recording();
  if (host.window) gtk_widget_hide(host.window);
  /* Keep pinned images in the source. Let only menus/settings disappear. */
  g_timeout_add(120, begin_capture, NULL);
}

static void recording_changed(gboolean busy, gboolean can_stop, const char *status, gpointer data) {
  (void)data;
  if (host.record_start_menu) gtk_widget_set_sensitive(host.record_start_menu, !busy && !host.quitting);
  if (host.record_stop_menu) {
    gtk_widget_set_sensitive(host.record_stop_menu, can_stop && !host.quitting);
    gtk_menu_item_set_label(GTK_MENU_ITEM(host.record_stop_menu), busy ? status : "停止录屏并保存");
  }
  if (host.indicator) app_indicator_set_label(host.indicator, busy ? "● REC" : "", "● REC");
  set_status(status);
}
static void menu_record(GtkWidget *widget, gpointer data) {
  (void)widget; (void)data;
  if (host.quitting || mc_linux_recording_busy()) return;
  if (mc_linux_capture_busy()) { set_status("请先完成或取消当前截图。"); return; }
  cancel_recording();
  if (host.window) gtk_widget_hide(host.window);
  mc_linux_recording_start();
}
static void menu_stop(GtkWidget *widget, gpointer data) {
  (void)widget; (void)data; mc_linux_recording_stop();
}

static void global_shortcut_action(unsigned index, gpointer data) {
  (void)data;
  /* The previous session remains usable while the desktop authorizes a
   * replacement, including its stop key for an ongoing recording. */
  if (host.quitting || host.recording >= 0) return;
  if (index == 0) menu_capture(NULL, NULL);
  else if (index == 1) menu_record(NULL, NULL);
  else if (index == 2) menu_stop(NULL, NULL);
}
static void global_shortcut_state(gboolean active, const char *message, const char *const labels[3], gpointer data) {
  (void)data; (void)active;
  g_free(host.shortcut_status); host.shortcut_status = g_strdup(message);
  for (unsigned i = 0; i < 3; i++) {
    g_free(host.shortcut_actual[i]); host.shortcut_actual[i] = labels ? g_strdup(labels[i]) : NULL;
  }
  if (host.shortcut_note) gtk_label_set_text(GTK_LABEL(host.shortcut_note), message);
  refresh_shortcuts();
}

static gboolean save_smoke_screenshot(void) {
  const char *path = g_getenv("MOOJICUT_SMOKE_SCREENSHOT");
  if (!path || !*path) return TRUE;
  while (gtk_events_pending()) gtk_main_iteration();
  GdkWindow *window = gtk_widget_get_window(host.window);
  if (!window) return FALSE;
  GdkPixbuf *image = gdk_pixbuf_get_from_window(window, 0, 0,
    gdk_window_get_width(window), gdk_window_get_height(window));
  if (!image) return FALSE;
  char *directory = g_path_get_dirname(path);
  GError *error = NULL;
  gboolean ok = g_mkdir_with_parents(directory, 0700) == 0 &&
    gdk_pixbuf_save(image, path, "png", &error, NULL);
  if (!ok) g_printerr("Cannot save smoke screenshot: %s\n", error ? error->message : path);
  g_clear_error(&error);
  g_free(directory);
  g_object_unref(image);
  return ok;
}

static MCShortcutFinished smoke_pending_finished;
static gpointer smoke_pending_data;
static void smoke_hold_shortcut_request(MCGlobalShortcuts *manager, const MCShortcutBinding bindings[3],
    const char *parent, MCShortcutCommit commit, MCShortcutFinished finished, gpointer data) {
  (void)manager; (void)bindings; (void)parent; (void)commit;
  smoke_pending_finished = finished; smoke_pending_data = data;
}
static gboolean smoke_shortcut_input_pending(void) {
  /* Suspend only the external request. Exercise the real recorder/key handler,
   * validation, transaction and old host actions without opening a portal. */
  show_preferences();
  gtk_notebook_set_current_page(GTK_NOTEBOOK(host.notebook), 1);
  begin_recording(NULL, GINT_TO_POINTER(0));
  gboolean passed = host.recording == 0;
  Shortcut previous = host.shortcuts[0];
  GdkEventKey key = {0}; key.keyval = GDK_KEY_8;
  key.hardware_keycode = XKeysymToKeycode(gdk_x11_display_get_xdisplay(gdk_display_get_default()), GDK_KEY_8);
  capture_key(host.window, &key, NULL);
  passed = host.recording == 0 && !host.shortcuts_pending && passed; /* Invalid input keeps recording. */
  request_shortcuts = smoke_hold_shortcut_request;
  key.state = GDK_CONTROL_MASK | GDK_SHIFT_MASK;
  capture_key(host.window, &key, NULL);
  request_shortcuts = mc_global_shortcuts_replace;
  passed = smoke_pending_finished && host.shortcuts_pending && host.recording == -1 &&
    !host.shortcut_keyboard_grabbed && passed;
  global_shortcut_action(1, NULL);
  passed = mc_linux_recording_busy() && passed;
  global_shortcut_action(2, NULL);
  passed = !mc_linux_recording_busy() && passed;
  if (smoke_pending_finished) {
    MCShortcutFinished finished = smoke_pending_finished; gpointer data = smoke_pending_data;
    smoke_pending_finished = NULL; smoke_pending_data = NULL;
    finished(FALSE, "模拟桌面取消授权，原快捷键保留。", data);
  }
  passed = !host.shortcuts_pending && host.shortcuts[0].key == previous.key &&
    host.shortcuts[0].mods == previous.mods && passed;
  cancel_recording();
  if (host.window) gtk_widget_destroy(host.window);
  g_print("Linux shortcut input/pending host route %s.\n", passed ? "passed" : "FAILED");
  return passed;
}

static GtkWidget *smoke_tool_setting(GtkWidget *parent, const char *id, const char *button_label) {
  if (GTK_IS_BUTTON(parent) && !g_strcmp0(g_object_get_data(G_OBJECT(parent), "tool-id"), id) &&
      (button_label ? !g_strcmp0(gtk_button_get_label(GTK_BUTTON(parent)), button_label) : GTK_IS_TOGGLE_BUTTON(parent)))
    return parent;
  if (!GTK_IS_CONTAINER(parent)) return NULL;
  GList *children = gtk_container_get_children(GTK_CONTAINER(parent));
  GtkWidget *found = NULL;
  for (GList *item = children; item && !found; item = item->next)
    found = smoke_tool_setting(item->data, id, button_label);
  g_list_free(children); return found;
}
static int smoke_tool_index(const char *id) {
  int count = tool_registry_snapshot_count(host.tool_snapshot, MC_TOOL_GROUP_SCREENSHOT);
  for (int index = 0; index < count; index++) {
    char *current = tool_text(host.tool_snapshot, index, MC_TOOL_ID);
    gboolean equal = !strcmp(current, id); g_free(current);
    if (equal) return index;
  }
  return -1;
}
static void smoke_tool_critical(const gchar *domain, GLogLevelFlags level,
    const gchar *message, gpointer data) {
  (*(guint *)data)++;
  g_log_default_handler(domain, level, message, NULL);
}
static gboolean smoke_flush_tool_settings(void) {
  for (int i = 0; i < 256 && host.tool_settings_refresh; i++)
    g_main_context_iteration(NULL, FALSE);
  return host.tool_settings_refresh == 0;
}
static gboolean smoke_tool_settings(void) {
  /* Exercise the actual GTK callbacks and disk boundary, not only pure snapshot
   * operations. A regular file as a parent makes the failure deterministic even
   * when the fixture runs with broad filesystem permissions. */
  char *original = g_strdup(host.tool_layout), *before = NULL, *after = NULL;
  guint criticals = 0;
  guint log_handler = g_log_set_handler("GLib-GObject", G_LOG_LEVEL_CRITICAL |
    G_LOG_FLAG_FATAL | G_LOG_FLAG_RECURSION, smoke_tool_critical, &criticals);
  gboolean ok = g_file_get_contents(host.config_path, &before, NULL, NULL);
  GList *windows = g_list_copy(gtk_application_get_windows(host.application));
  GdkPixbuf *image = gdk_pixbuf_new(GDK_COLORSPACE_RGB, FALSE, 8, 32, 24);
  GtkWidget *pinned = NULL;
  if (image) {
    gdk_pixbuf_fill(image, 0x336699ff); mc_linux_pin_image(image); g_object_unref(image);
    for (GList *item = gtk_application_get_windows(host.application); item; item = item->next)
      if (!g_list_find(windows, item->data)) { pinned = item->data; break; }
  }
  g_list_free(windows);
  if (pinned) g_object_add_weak_pointer(G_OBJECT(pinned), (gpointer *)&pinned); else ok = FALSE;
  int previous = host.tool_snapshot;
  char *path = host.config_path;
  host.config_path = g_build_filename(path, "blocked", NULL);
  GtkWidget *toggle = smoke_tool_setting(host.tool_settings, "builtin.image.arrow", NULL);
  GtkWidget *retired_toggle = toggle;
  if (retired_toggle) g_object_add_weak_pointer(G_OBJECT(retired_toggle), (gpointer *)&retired_toggle);
  if (toggle) gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(toggle), FALSE); else ok = FALSE;
  guint pending_refresh = host.tool_settings_refresh;
  ok = retired_toggle && pending_refresh && ok;
  gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(host.pin_toggle), FALSE);
  ok = pinned && host.pin_enabled && mc_linux_pins_enabled() &&
    gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(host.pin_toggle)) &&
    host.tool_settings_refresh == pending_refresh && ok;
  g_free(host.config_path); host.config_path = path;
  ok = smoke_flush_tool_settings() && !retired_toggle && ok;
  if (retired_toggle) g_object_remove_weak_pointer(G_OBJECT(retired_toggle), (gpointer *)&retired_toggle);
  toggle = smoke_tool_setting(host.tool_settings, "builtin.image.arrow", NULL);
  ok = host.tool_snapshot == previous && !g_strcmp0(host.tool_layout, original) && toggle &&
    gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(toggle)) && ok;
  ok = g_file_get_contents(path, &after, NULL, NULL) && !g_strcmp0(before, after) && ok;
  g_free(before); g_free(after);

  char *pin_id = tool_text(host.tool_snapshot, tool_action_index(host.tool_snapshot, "pin"), MC_TOOL_ID);
  toggle = smoke_tool_setting(host.tool_settings, pin_id, NULL);
  if (toggle) gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(toggle), FALSE); else ok = FALSE;
  ok = !pinned && !host.pin_enabled && !mc_linux_pins_enabled() &&
    !gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(host.pin_toggle)) && ok;
  gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(host.pin_toggle), TRUE);
  ok = smoke_flush_tool_settings() && ok;
  toggle = smoke_tool_setting(host.tool_settings, pin_id, NULL);
  ok = host.pin_enabled && mc_linux_pins_enabled() && toggle &&
    gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(toggle)) && ok;
  g_free(pin_id);

  toggle = smoke_tool_setting(host.tool_settings, "builtin.image.numberedRectangle", NULL);
  if (toggle) gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(toggle), TRUE); else ok = FALSE;
  int index = smoke_tool_index("builtin.image.numberedRectangle");
  ok = host.tool_snapshot != previous && index >= 0 &&
    tool_registry_snapshot_value(host.tool_snapshot, MC_TOOL_GROUP_SCREENSHOT, index, MC_TOOL_ENABLED) == 1 && ok;
  GKeyFile *saved = g_key_file_new();
  ok = g_key_file_load_from_file(saved, path, G_KEY_FILE_NONE, NULL) && ok;
  char *stored = g_key_file_get_string(saved, "Tools", "layout", NULL);
  ok = !g_strcmp0(stored, host.tool_layout) && ok;
  load_settings();
  ok = !g_strcmp0(host.tool_layout, stored) && ok;
  g_free(stored); g_key_file_unref(saved);

  int arrow_before = smoke_tool_index("builtin.image.arrow");
  GtkWidget *up = smoke_tool_setting(host.tool_settings, "builtin.image.arrow", "↑");
  if (up) gtk_button_clicked(GTK_BUTTON(up)); else ok = FALSE;
  ok = arrow_before > 0 && smoke_tool_index("builtin.image.arrow") == arrow_before - 1 && ok;
  char *moved = g_strdup(host.tool_layout); load_settings();
  ok = !g_strcmp0(host.tool_layout, moved) && ok; g_free(moved);
  ok = publish_tools(open_tools(original)) && !g_strcmp0(host.tool_layout, original) && ok;
  /* Closing before the queued refresh must cancel its retained old container.
   * A later main-loop turn must not rebuild the newly opened settings window. */
  GtkWidget *retired_settings = host.tool_settings;
  g_object_add_weak_pointer(G_OBJECT(retired_settings), (gpointer *)&retired_settings);
  ok = host.tool_settings_refresh != 0 && ok;
  gtk_widget_destroy(host.window);
  ok = !host.window && !host.tool_settings_refresh && !retired_settings && ok;
  if (retired_settings) g_object_remove_weak_pointer(G_OBJECT(retired_settings), (gpointer *)&retired_settings);
  show_preferences();
  GtkWidget *current_toggle = smoke_tool_setting(host.tool_settings, "builtin.image.arrow", NULL);
  if (current_toggle) g_object_add_weak_pointer(G_OBJECT(current_toggle), (gpointer *)&current_toggle);
  for (int i = 0; i < 32; i++) g_main_context_iteration(NULL, FALSE);
  ok = current_toggle && smoke_tool_setting(host.tool_settings, "builtin.image.arrow", NULL) == current_toggle &&
    !g_strcmp0(host.tool_layout, original) && ok;
  if (current_toggle) g_object_remove_weak_pointer(G_OBJECT(current_toggle), (gpointer *)&current_toggle);
  g_free(original);

  host.config_path = g_build_filename(host.smoke_dir, "legacy-tools.ini", NULL);
  ok = g_file_set_contents(host.config_path, "[Features]\npin-enabled=false\n", -1, NULL) && ok;
  load_settings();
  ok = !host.pin_enabled && !mc_linux_pins_enabled() && save_settings() && ok;
  saved = g_key_file_new();
  ok = g_key_file_load_from_file(saved, host.config_path, G_KEY_FILE_NONE, NULL) &&
    g_key_file_has_key(saved, "Tools", "layout", NULL) &&
    !g_key_file_has_key(saved, "Features", "pin-enabled", NULL) && ok;
  /* An old writer's contradictory legacy field must not override the layout. */
  g_key_file_set_boolean(saved, "Features", "pin-enabled", TRUE);
  ok = g_key_file_save_to_file(saved, host.config_path, NULL) && ok;
  g_key_file_unref(saved); load_settings();
  ok = !host.pin_enabled && !mc_linux_pins_enabled() && ok;
  g_unlink(host.config_path); g_free(host.config_path); host.config_path = path; load_settings();
  ok = host.pin_enabled && mc_linux_pins_enabled() && ok;
  if (pinned) { g_object_remove_weak_pointer(G_OBJECT(pinned), (gpointer *)&pinned); mc_linux_pins_close(); }
  g_log_remove_handler("GLib-GObject", log_handler);
  ok = criticals == 0 && ok;
  g_print("Linux contribution settings fixture %s: failed save rollback, GTK enable/reorder, deferred refresh lifetime, close/reopen, zero GObject criticals, single pin preference, legacy migration/readback.\n", ok ? "passed" : "FAILED");
  return ok;
}

static gboolean smoke_check(gpointer data) {
  (void)data;
  gboolean passed = host.core_ok && host.window && gtk_widget_get_visible(host.window);
  passed = passed && gtk_notebook_get_n_pages(GTK_NOTEBOOK(host.notebook)) == 6;
  passed = save_smoke_screenshot() && passed;
  gtk_notebook_set_current_page(GTK_NOTEBOOK(host.notebook), 1);
  passed = passed && validate_shortcut(0, host.shortcuts[1]) == 2;
  passed = passed && update_shortcut(0, (Shortcut){ '9', 5 });
  passed = passed && update_shortcut(2, (Shortcut){ 0, 0 });
  gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(host.dark_toggle), TRUE);
  load_settings();
  passed = passed && host.shortcuts[0].key == '9' && host.shortcuts[2].key == 0 && host.prefer_dark;
  gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(host.pin_toggle), FALSE);
  load_settings();
  passed = !host.pin_enabled && !mc_linux_pins_enabled() && passed;
  gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(host.pin_toggle), TRUE);
  load_settings();
  passed = host.pin_enabled && mc_linux_pins_enabled() && passed;
  begin_recording(NULL, GINT_TO_POINTER(0));
  gtk_notebook_set_current_page(GTK_NOTEBOOK(host.notebook), 2);
  passed = passed && host.recording == -1;
  for (int i = 0; i < 5; i++) {
    gtk_widget_destroy(host.window);
    passed = passed && !host.window && !host.recorders[0];
    show_preferences();
    passed = passed && host.window && gtk_widget_get_visible(host.window);
  }
  reset_shortcuts(NULL, NULL);
  load_settings();
  passed = passed && memcmp(host.shortcuts, defaults, sizeof(defaults)) == 0;
  passed = smoke_tool_settings() && passed;
  gtk_widget_destroy(host.window);
  passed = passed && host.window == NULL;
  passed = mc_linux_capture_smoke(host.application) && passed;
  passed = mc_linux_pin_smoke() && passed;
  passed = mc_linux_recording_smoke(host.application, host.smoke_dir) && passed;
  passed = smoke_shortcut_input_pending() && passed;
  passed = mc_linux_update_smoke() && passed;
  passed = mc_global_shortcuts_x11_smoke() && passed;
  host.exit_code = passed ? 0 : 1;
  g_print("Linux native UI smoke %s: core, settings persistence, clear/reset, duplicate validation, five close/reopen cycles.\n", passed ? "passed" : "FAILED");
  g_application_quit(G_APPLICATION(host.application));
  return G_SOURCE_REMOVE;
}

static void restore_pins(GtkWidget *widget, gpointer data) {
  (void)widget;(void)data;mc_linux_pins_restore();
}
static void restore_pin_input(GtkWidget *widget, gpointer data) {
  (void)widget;(void)data;mc_linux_pins_restore_input();
}
static void close_pins(GtkWidget *widget, gpointer data) {
  (void)widget; (void)data; mc_linux_pins_close_interactive();
}

static void startup(GApplication *application, gpointer data) {
  (void)data;
  g_application_hold(application);
  g_object_get(gtk_settings_get_default(), "gtk-application-prefer-dark-theme", &host.system_dark, NULL);
  load_settings();
  mc_linux_recording_init(host.application, recording_changed, NULL);
  mc_linux_pins_init(host.application, host.config_path);
  host.pins_ready = TRUE;
  sync_pin_feature();
  const MCShortcutDescriptor descriptors[3] = {
    {action_ids[0], action_labels[0]}, {action_ids[1], action_labels[1]}, {action_ids[2], action_labels[2]}
  };
  host.global_shortcuts = mc_global_shortcuts_new(gdk_display_get_default(), descriptors, global_shortcut_action, global_shortcut_state, NULL);
  if (!mc_global_shortcuts_is_portal(host.global_shortcuts)) replace_shortcuts(host.shortcuts, FALSE);
  g_object_set(gtk_settings_get_default(), "gtk-application-prefer-dark-theme", host.prefer_dark || host.system_dark, NULL);
  host.indicator = app_indicator_new("moojicut", host.icon_path, APP_INDICATOR_CATEGORY_APPLICATION_STATUS);
  app_indicator_set_title(host.indicator, "Mooji Cut");
  app_indicator_set_icon_full(host.indicator, host.icon_path, "Mooji Cut");
  GtkWidget *menu = gtk_menu_new();
  GtkWidget *screenshot = gtk_menu_item_new_with_label("截图并标注…");
  g_signal_connect(screenshot, "activate", G_CALLBACK(menu_capture), NULL);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), screenshot);
  host.record_start_menu = gtk_menu_item_new_with_label("开始录屏…");
  g_signal_connect(host.record_start_menu, "activate", G_CALLBACK(menu_record), NULL);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), host.record_start_menu);
  host.record_stop_menu = gtk_menu_item_new_with_label("停止录屏并保存");
  g_signal_connect(host.record_stop_menu, "activate", G_CALLBACK(menu_stop), NULL);
  gtk_widget_set_sensitive(host.record_stop_menu, FALSE);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), host.record_stop_menu);
  GtkWidget *restore = gtk_menu_item_new_with_label("恢复隐藏贴图");
  host.pin_menu[0] = restore;
  g_signal_connect(restore,"activate",G_CALLBACK(restore_pins),NULL);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu),restore);
  GtkWidget *restore_input = gtk_menu_item_new_with_label("关闭鼠标穿透");
  host.pin_menu[1] = restore_input;
  g_signal_connect(restore_input,"activate",G_CALLBACK(restore_pin_input),NULL);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu),restore_input);
  GtkWidget *pins = gtk_menu_item_new_with_label("关闭所有贴图");
  host.pin_menu[2] = pins;
  g_signal_connect(pins, "activate", G_CALLBACK(close_pins), NULL);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), pins);
  GtkWidget *preferences = gtk_menu_item_new_with_label("设置…");
  g_signal_connect(preferences, "activate", G_CALLBACK(menu_preferences), NULL);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), preferences);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), gtk_separator_menu_item_new());
  GtkWidget *quit = gtk_menu_item_new_with_label("退出 Mooji Cut");
  g_signal_connect(quit, "activate", G_CALLBACK(quit_app), NULL);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), quit);
  gtk_widget_show_all(menu);
  sync_pin_feature();
  app_indicator_set_menu(host.indicator, GTK_MENU(menu));
  app_indicator_set_status(host.indicator, APP_INDICATOR_STATUS_ACTIVE);
}

static int command_line(GApplication *application, GApplicationCommandLine *command, gpointer data) {
  (void)application; (void)data;
  if (host.quitting) return 0;
  GVariantDict *options = g_application_command_line_get_options_dict(command);
  if (g_variant_dict_contains(options, "capture")) menu_capture(NULL, NULL);
  else if (g_variant_dict_contains(options, "record")) menu_record(NULL, NULL);
  else if (g_variant_dict_contains(options, "stop")) menu_stop(NULL, NULL);
  else if (g_variant_dict_contains(options, "preferences") || host.activated || host.smoke) show_preferences();
  if (host.smoke && !host.activated) g_timeout_add(300, smoke_check, NULL);
  host.activated = TRUE;
  return 0;
}

int main(int argc, char **argv) {
  /* ximagesrc uses Xlib on media threads. This must precede GTK/Xlib work. */
  XInitThreads();
  gboolean self_test = FALSE;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--self-test")) self_test = TRUE;
    if (!strcmp(argv[i], "--smoke")) host.smoke = TRUE;
  }
  moonbit_init();
  host.core_ok = preview_core_check() == 1;
  host.recording = -1;
  if (self_test) {
    for (int i = 0; i < 1000 && host.core_ok; i++) host.core_ok = preview_core_check() == 1;
    g_print("MoonBit native core %s (1000 repeated checks).\n", host.core_ok ? "passed" : "FAILED");
    return host.core_ok ? 0 : 1;
  }
  if (!host.core_ok) {
    g_printerr("MoonBit native core failed its startup check.\n");
    return 1;
  }
  GError *error = NULL;
  if (host.smoke) {
    host.smoke_dir = g_dir_make_tmp("moojicut-smoke-XXXXXX", &error);
    if (!host.smoke_dir) { g_printerr("%s\n", error->message); g_error_free(error); return 1; }
    host.config_path = g_build_filename(host.smoke_dir, "settings.ini", NULL);
  } else host.config_path = g_build_filename(g_get_user_config_dir(), "moojicut", "settings.ini", NULL);
  char *executable = g_file_read_link("/proc/self/exe", NULL);
  char *directory = executable ? g_path_get_dirname(executable) : g_get_current_dir();
  host.icon_path = g_build_filename(directory, "moojicut.png", NULL);
  g_free(directory);
  g_free(executable);
  GApplicationFlags flags = G_APPLICATION_HANDLES_COMMAND_LINE;
  if (host.smoke) flags = (GApplicationFlags)(flags | G_APPLICATION_NON_UNIQUE);
  host.application = gtk_application_new("dev.moojicut.native", flags);
  const GOptionEntry options[] = {
    { "preferences", 0, 0, G_OPTION_ARG_NONE, NULL, "Open preferences", NULL },
    { "capture", 0, 0, G_OPTION_ARG_NONE, NULL, "Capture and annotate a screenshot", NULL },
    { "record", 0, 0, G_OPTION_ARG_NONE, NULL, "Record a silent screen/region/window video", NULL },
    { "stop", 0, 0, G_OPTION_ARG_NONE, NULL, "Stop/cancel recording and preserve the original", NULL },
    { "smoke", 0, G_OPTION_FLAG_HIDDEN, G_OPTION_ARG_NONE, NULL, "Run isolated native UI checks", NULL },
    { NULL, 0, 0, G_OPTION_ARG_NONE, NULL, NULL, NULL }
  };
  g_application_add_main_option_entries(G_APPLICATION(host.application), options);
  g_signal_connect(host.application, "startup", G_CALLBACK(startup), NULL);
  g_signal_connect(host.application, "command-line", G_CALLBACK(command_line), NULL);
  int result = g_application_run(G_APPLICATION(host.application), argc, argv);
  host.quitting = TRUE;
  MCGlobalShortcuts *shortcuts = host.global_shortcuts; host.global_shortcuts = NULL;
  mc_global_shortcuts_close(shortcuts);
  cancel_recording();
  mc_linux_capture_close();
  mc_linux_capture_publish_tools(0);
  if (host.tool_snapshot > 0) tool_registry_snapshot_close(host.tool_snapshot);
  mc_linux_pins_set_enabled(FALSE);
  if (host.window) gtk_widget_destroy(host.window);
  if (host.indicator) {
    app_indicator_set_status(host.indicator, APP_INDICATOR_STATUS_PASSIVE);
    g_object_unref(host.indicator);
  }
  g_object_unref(host.application);
  if (host.smoke_dir) { char *pins = g_strconcat(host.config_path, ".pins", NULL); g_unlink(pins); g_free(pins); g_unlink(host.config_path); g_rmdir(host.smoke_dir); }
  g_free(host.smoke_dir);
  g_free(host.config_path);
  g_free(host.icon_path);
  g_free(host.shortcut_status);
  g_free(host.tool_layout);
  for (unsigned i = 0; i < 3; i++) g_free(host.shortcut_actual[i]);
  return result ? result : host.exit_code;
}
