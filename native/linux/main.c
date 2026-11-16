#include <gtk/gtk.h>
#include <libayatana-appindicator/app-indicator.h>
#include <glib/gstdio.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "moonbit.h"
#include "plugins/feature/capture/linux/capture.h"
#include "plugins/feature/pin/linux/pinning.h"
#include "updates.h"

#ifndef MOOJICUT_VERSION
#define MOOJICUT_VERSION "development"
#endif

extern int32_t preview_core_check(void);
extern int32_t shortcut_validate(int32_t, int32_t, int32_t, int32_t, int32_t, int32_t);

typedef struct { int key; int mods; } Shortcut;
typedef struct {
  GtkApplication *application;
  AppIndicator *indicator;
  GtkWidget *window, *notebook, *status, *recorders[3], *dark_toggle, *pin_toggle, *pin_menu[3];
  Shortcut shortcuts[3];
  gboolean prefer_dark, system_dark, smoke, activated, core_ok, pin_enabled, quitting;
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
    char *label = shortcut_label(host.shortcuts[i]);
    gtk_button_set_label(GTK_BUTTON(host.recorders[i]), i == host.recording ? "按下快捷键…" : label);
    g_free(label);
  }
}

static gboolean save_settings(void) {
  GKeyFile *settings = g_key_file_new();
  g_key_file_set_boolean(settings, "General", "prefer-dark", host.prefer_dark);
  g_key_file_set_boolean(settings, "Features", "pin-enabled", host.pin_enabled);
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

static void load_settings(void) {
  memcpy(host.shortcuts, defaults, sizeof(defaults));
  host.prefer_dark = FALSE;
  host.pin_enabled = TRUE;
  GKeyFile *settings = g_key_file_new();
  if (g_key_file_load_from_file(settings, host.config_path, G_KEY_FILE_NONE, NULL)) {
    host.prefer_dark = g_key_file_get_boolean(settings, "General", "prefer-dark", NULL);
    if (g_key_file_has_key(settings, "Features", "pin-enabled", NULL))
      host.pin_enabled = g_key_file_get_boolean(settings, "Features", "pin-enabled", NULL);
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
  g_key_file_unref(settings);
}

static gboolean update_shortcut(int index, Shortcut value) {
  int result = validate_shortcut(index, value);
  if (result) {
    set_status(result == 1 ? "字母或数字请搭配 Ctrl、Alt 或 Super。" :
      result == 2 ? "这个组合已用于另一个操作，请换一个。" : "支持字母、数字及 F1–F24 功能键。");
    return FALSE;
  }
  Shortcut previous = host.shortcuts[index];
  host.shortcuts[index] = value;
  if (!save_settings()) {
    host.shortcuts[index] = previous;
    return FALSE;
  }
  cancel_recording();
  set_status("已保存。全局采集动作将在后续版本接入。");
  return TRUE;
}

static void cancel_recording(void) {
  host.recording = -1;
  refresh_shortcuts();
}

static void begin_recording(GtkButton *button, gpointer data) {
  (void)button;
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
  Shortcut previous[3];
  memcpy(previous, host.shortcuts, sizeof(previous));
  memcpy(host.shortcuts, defaults, sizeof(defaults));
  if (!save_settings()) memcpy(host.shortcuts, previous, sizeof(previous));
  else set_status("已恢复默认快捷键。");
  cancel_recording();
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
  mc_linux_pins_set_enabled(host.pin_enabled);
  mc_linux_capture_refresh_capabilities();
  for (int i = 0; i < 3; i++)
    if (host.pin_menu[i]) gtk_widget_set_sensitive(host.pin_menu[i], host.pin_enabled);
}
static void pin_feature_changed(GtkToggleButton *button, gpointer data) {
  (void)data;
  gboolean previous = host.pin_enabled;
  host.pin_enabled = gtk_toggle_button_get_active(button);
  /* Persist first: a failed write must not irreversibly discard existing pins. */
  if (!save_settings()) {
    host.pin_enabled = previous;
    g_signal_handlers_block_by_func(button, pin_feature_changed, NULL);
    gtk_toggle_button_set_active(button, previous);
    g_signal_handlers_unblock_by_func(button, pin_feature_changed, NULL);
    return;
  }
  sync_pin_feature();
  set_status(host.pin_enabled ? "贴图已启用。" : "贴图已关闭，当前贴图与全局按键已释放；按键配置保留。");
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

static void window_destroyed(GtkWidget *widget, gpointer data) {
  (void)widget; (void)data;
  host.window = host.notebook = host.status = host.dark_toggle = host.pin_toggle = NULL;
  memset(host.recorders, 0, sizeof(host.recorders));
  host.recording = -1;
}

static void quit_app(GtkWidget *widget, gpointer data) {
  (void)widget; (void)data;
  if (host.quitting) return;
  host.quitting = TRUE;
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
  gtk_box_pack_start(GTK_BOX(shortcuts), label("配置自动保存；截图全局快捷键尚未接入，请从托盘菜单或通用设置启动。贴图全局恢复键见“贴图按键”；录屏仍在开发中。", TRUE), FALSE, FALSE, 0);
  gtk_notebook_append_page(GTK_NOTEBOOK(host.notebook), shortcuts, gtk_label_new("快捷键"));
  gtk_notebook_append_page(GTK_NOTEBOOK(host.notebook), mc_linux_pin_preferences(), gtk_label_new("贴图按键"));
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
  gtk_box_pack_start(GTK_BOX(about), label("Linux 原生预览版\n截图后原地标注、编辑文字、确认复制或固定贴图。X11 保留冻结桌面；Wayland 由系统门户提供截图，编辑位置与贴图置顶由桌面决定。录屏仍在开发中。", TRUE), FALSE, FALSE, 0);
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
  if (host.quitting) return G_SOURCE_REMOVE;
  mc_linux_capture_start(host.application, &capture_host);
  return G_SOURCE_REMOVE;
}

static void menu_capture(GtkWidget *widget, gpointer data) {
  (void)widget; (void)data;
  cancel_recording();
  if (host.window) gtk_widget_hide(host.window);
  /* Keep pinned images in the source. Let only menus/settings disappear. */
  g_timeout_add(120, begin_capture, NULL);
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

static gboolean smoke_check(gpointer data) {
  (void)data;
  gboolean passed = host.core_ok && host.window && gtk_widget_get_visible(host.window);
  passed = passed && gtk_notebook_get_n_pages(GTK_NOTEBOOK(host.notebook)) == 5;
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
  gtk_widget_destroy(host.window);
  passed = passed && host.window == NULL;
  passed = mc_linux_capture_smoke(host.application) && passed;
  passed = mc_linux_pin_smoke() && passed;
  passed = mc_linux_update_smoke() && passed;
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
  mc_linux_pins_init(host.application, host.config_path);
  mc_linux_pins_set_enabled(host.pin_enabled);
  g_object_set(gtk_settings_get_default(), "gtk-application-prefer-dark-theme", host.prefer_dark || host.system_dark, NULL);
  host.indicator = app_indicator_new("moojicut", host.icon_path, APP_INDICATOR_CATEGORY_APPLICATION_STATUS);
  app_indicator_set_title(host.indicator, "Mooji Cut");
  app_indicator_set_icon_full(host.indicator, host.icon_path, "Mooji Cut");
  GtkWidget *menu = gtk_menu_new();
  GtkWidget *screenshot = gtk_menu_item_new_with_label("截图并标注…");
  g_signal_connect(screenshot, "activate", G_CALLBACK(menu_capture), NULL);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), screenshot);
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
  else if (g_variant_dict_contains(options, "preferences") || host.activated || host.smoke) show_preferences();
  if (host.smoke && !host.activated) g_timeout_add(300, smoke_check, NULL);
  host.activated = TRUE;
  return 0;
}

int main(int argc, char **argv) {
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
    { "smoke", 0, G_OPTION_FLAG_HIDDEN, G_OPTION_ARG_NONE, NULL, "Run isolated native UI checks", NULL },
    { NULL, 0, 0, G_OPTION_ARG_NONE, NULL, NULL, NULL }
  };
  g_application_add_main_option_entries(G_APPLICATION(host.application), options);
  g_signal_connect(host.application, "startup", G_CALLBACK(startup), NULL);
  g_signal_connect(host.application, "command-line", G_CALLBACK(command_line), NULL);
  int result = g_application_run(G_APPLICATION(host.application), argc, argv);
  mc_linux_capture_close();
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
  return result ? result : host.exit_code;
}
