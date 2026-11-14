#include "pinning.h"
#include <glib/gstdio.h>
#include <math.h>
#include <string.h>

typedef struct {
  guint key;
  GdkModifierType mods;
} Binding;
typedef struct {
  GtkWidget *window, *canvas;
  GdkPixbuf *image;
  double scale, opacity;
  gboolean selected;
} Pin;
static GtkApplication *application;
static GSList *pins;
static char *settings_path;
static Binding bindings[4];
static const Binding defaults[4] = {{GDK_KEY_plus, 0},
                                    {GDK_KEY_minus, 0},
                                    {GDK_KEY_plus, GDK_CONTROL_MASK},
                                    {GDK_KEY_minus, GDK_CONTROL_MASK}};
static const char *names[] = {"放大贴图", "缩小贴图", "增加不透明度", "降低不透明度"};
static GtkWidget *recorders[4], *status;
static int recording = -1;

static Binding normalize(guint key, GdkModifierType mods) {
  mods &= GDK_CONTROL_MASK | GDK_MOD1_MASK | GDK_SHIFT_MASK | GDK_SUPER_MASK;
  if (key == GDK_KEY_equal || key == GDK_KEY_KP_Add || key == GDK_KEY_plus) {
    key = GDK_KEY_plus;
    mods &= ~GDK_SHIFT_MASK;
  }
  if (key == GDK_KEY_KP_Subtract)
    key = GDK_KEY_minus;
  return (Binding){gdk_keyval_to_lower(key), mods};
}
static gboolean same(Binding a, Binding b) {
  return a.key == b.key && a.mods == b.mods;
}
static gboolean save(void) {
  GKeyFile *file = g_key_file_new();
  for (int i = 0; i < 4; i++) {
    char key[8];
    g_snprintf(key, sizeof(key), "key%d", i);
    int values[] = {(int)bindings[i].key, (int)bindings[i].mods};
    g_key_file_set_integer_list(file, "Pins", key, values, 2);
  }
  gsize length;
  char *data = g_key_file_to_data(file, &length, NULL), *dir = g_path_get_dirname(settings_path);
  gboolean ok =
      g_mkdir_with_parents(dir, 0700) == 0 && g_file_set_contents(settings_path, data, (gssize)length, NULL);
  if (ok)
    g_chmod(settings_path, 0600);
  g_free(data);
  g_free(dir);
  g_key_file_unref(file);
  return ok;
}
void mc_linux_pins_init(GtkApplication *app, const char *path) {
  application = app;
  g_free(settings_path);
  settings_path = g_strconcat(path, ".pins", NULL);
  memcpy(bindings, defaults, sizeof(bindings));
  GKeyFile *file = g_key_file_new();
  if (g_key_file_load_from_file(file, settings_path, G_KEY_FILE_NONE, NULL)) {
    for (int i = 0; i < 4; i++) {
      char key[8];
      g_snprintf(key, sizeof(key), "key%d", i);
      gsize n = 0;
      int *v = g_key_file_get_integer_list(file, "Pins", key, &n, NULL);
      if (v && n == 2)
        bindings[i] = normalize((guint)v[0], (GdkModifierType)v[1]);
      g_free(v);
    }
    for (int i = 0; i < 4; i++)
      for (int j = 0; j < i; j++)
        if (bindings[i].key && same(bindings[i], bindings[j]))
          memcpy(bindings, defaults, sizeof(bindings));
  }
  g_key_file_unref(file);
}
static void resize_pin(Pin *pin, double scale) {
  GdkMonitor *monitor = gdk_display_get_monitor_at_window(gtk_widget_get_display(pin->window),
                                                          gtk_widget_get_window(pin->window));
  GdkRectangle area = {0, 0, 1920, 1080};
  if (monitor)
    gdk_monitor_get_workarea(monitor, &area);
  double fit = fmin((double)area.width / gdk_pixbuf_get_width(pin->image),
                    (double)area.height / gdk_pixbuf_get_height(pin->image));
  pin->scale = CLAMP(scale, fmin(0.1, fit), fmin(8.0, fit));
  int w = MAX(1, (int)round(gdk_pixbuf_get_width(pin->image) * pin->scale)),
      h = MAX(1, (int)round(gdk_pixbuf_get_height(pin->image) * pin->scale));
  gtk_widget_set_size_request(pin->canvas, w, h);
  gtk_window_resize(GTK_WINDOW(pin->window), w, h);
  gtk_widget_queue_draw(pin->canvas);
}
static gboolean draw(GtkWidget *widget, cairo_t *cr, gpointer data) {
  (void)widget;
  Pin *pin = data;
  cairo_save(cr);
  cairo_scale(cr, pin->scale, pin->scale);
  gdk_cairo_set_source_pixbuf(cr, pin->image, 0, 0);
  cairo_paint(cr);
  cairo_restore(cr);
  if (pin->selected) {
    int w = gtk_widget_get_allocated_width(pin->canvas), h = gtk_widget_get_allocated_height(pin->canvas);
    cairo_rectangle(cr, 1, 1, w - 2, h - 2);
    cairo_set_source_rgb(cr, .2, .17, .23);
    cairo_set_line_width(cr, 3);
    cairo_stroke_preserve(cr);
    cairo_set_source_rgb(cr, .76, .75, .73);
    cairo_set_line_width(cr, 1);
    cairo_stroke(cr);
  }
  return FALSE;
}
static void destroyed(GtkWidget *widget, gpointer data) {
  (void)widget;
  Pin *pin = data;
  pins = g_slist_remove(pins, pin);
  g_object_unref(pin->image);
  g_free(pin);
}
static gboolean focus(GtkWidget *widget, GdkEventFocus *event, gpointer data) {
  (void)widget;
  Pin *pin = data;
  pin->selected = event->in;
  gtk_widget_queue_draw(pin->canvas);
  return FALSE;
}
static void apply(Pin *pin, int action) {
  if (action < 2)
    resize_pin(pin, pin->scale * (action == 0 ? 1.1 : 1 / 1.1));
  else {
    pin->opacity = CLAMP(pin->opacity + (action == 2 ? .1 : -.1), .1, 1);
    gtk_widget_set_opacity(pin->window, pin->opacity);
  }
}
static gboolean key(GtkWidget *widget, GdkEventKey *event, gpointer data) {
  (void)widget;
  Pin *pin = data;
  if (!pin->selected)
    return FALSE;
  if (event->keyval == GDK_KEY_Escape) {
    pin->selected = FALSE;
    gtk_widget_queue_draw(pin->canvas);
    return TRUE;
  }
  if (event->keyval == GDK_KEY_Delete) {
    gtk_widget_destroy(pin->window);
    return TRUE;
  }
  Binding value = normalize(event->keyval, event->state);
  for (int i = 0; i < 4; i++)
    if (bindings[i].key && same(value, bindings[i])) {
      apply(pin, i);
      return TRUE;
    }
  return FALSE;
}
static void copy(GtkMenuItem *item, gpointer data) {
  (void)item;
  Pin *pin = data;
  GtkClipboard *clip = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  gtk_clipboard_set_image(clip, pin->image);
  gtk_clipboard_set_can_store(clip, NULL, 0);
  gtk_clipboard_store(clip);
}
static void reset(GtkMenuItem *item, gpointer data) {
  (void)item;
  Pin *pin = data;
  pin->opacity = 1;
  gtk_widget_set_opacity(pin->window, 1);
  resize_pin(pin, 1);
}
static void close_pin(GtkMenuItem *item, gpointer data) {
  (void)item;
  gtk_widget_destroy(((Pin *)data)->window);
}
static gboolean press(GtkWidget *widget, GdkEventButton *event, gpointer data) {
  (void)widget;
  Pin *pin = data;
  pin->selected = TRUE;
  gtk_window_present(GTK_WINDOW(pin->window));
  gtk_widget_queue_draw(pin->canvas);
  if (event->button == 1) {
    gtk_window_begin_move_drag(GTK_WINDOW(pin->window), 1, (int)event->x_root, (int)event->y_root,
                               event->time);
    return TRUE;
  }
  if (event->button == 3) {
    GtkWidget *menu = gtk_menu_new();
    const char *labels[] = {"复制图片", "恢复大小与透明度", "关闭贴图"};
    GCallback handlers[] = {G_CALLBACK(copy), G_CALLBACK(reset), G_CALLBACK(close_pin)};
    for (int i = 0; i < 3; i++) {
      GtkWidget *item = gtk_menu_item_new_with_label(labels[i]);
      g_signal_connect(item, "activate", handlers[i], pin);
      gtk_menu_shell_append(GTK_MENU_SHELL(menu), item);
    }
    g_signal_connect_swapped(menu, "selection-done", G_CALLBACK(gtk_widget_destroy), menu);
    gtk_widget_show_all(menu);
    gtk_menu_popup_at_pointer(GTK_MENU(menu), (GdkEvent *)event);
    return TRUE;
  }
  return FALSE;
}
void mc_linux_pin_image(GdkPixbuf *image) {
  if (!image)
    return;
  Pin *pin = g_new0(Pin, 1);
  pin->image = g_object_ref(image);
  pin->scale = pin->opacity = 1;
  pin->selected = TRUE;
  pin->window = gtk_application_window_new(application);
  gtk_window_set_title(GTK_WINDOW(pin->window), "Mooji Cut · 贴图");
  gtk_window_set_decorated(GTK_WINDOW(pin->window), FALSE);
  gtk_window_set_keep_above(GTK_WINDOW(pin->window), TRUE);
  gtk_window_set_skip_taskbar_hint(GTK_WINDOW(pin->window), TRUE);
  gtk_window_set_skip_pager_hint(GTK_WINDOW(pin->window), TRUE);
  gtk_window_stick(GTK_WINDOW(pin->window));
  gtk_window_set_resizable(GTK_WINDOW(pin->window), FALSE);
  pin->canvas = gtk_drawing_area_new();
  gtk_widget_add_events(pin->canvas, GDK_BUTTON_PRESS_MASK);
  gtk_container_add(GTK_CONTAINER(pin->window), pin->canvas);
  g_signal_connect(pin->canvas, "draw", G_CALLBACK(draw), pin);
  g_signal_connect(pin->canvas, "button-press-event", G_CALLBACK(press), pin);
  g_signal_connect(pin->window, "key-press-event", G_CALLBACK(key), pin);
  g_signal_connect(pin->window, "focus-in-event", G_CALLBACK(focus), pin);
  g_signal_connect(pin->window, "focus-out-event", G_CALLBACK(focus), pin);
  g_signal_connect(pin->window, "destroy", G_CALLBACK(destroyed), pin);
  pins = g_slist_prepend(pins, pin);
  gtk_widget_realize(pin->window);
  resize_pin(pin, 1);
  gtk_widget_show_all(pin->window);
  gtk_window_present(GTK_WINDOW(pin->window));
}
void mc_linux_pins_hide(gboolean hidden) {
  for (GSList *node = pins; node; node = node->next) {
    Pin *pin = node->data;
    if (hidden)
      gtk_widget_hide(pin->window);
    else
      gtk_widget_show(pin->window);
  }
}
void mc_linux_pins_close(void) {
  while (pins)
    gtk_widget_destroy(((Pin *)pins->data)->window);
}
static void refresh(void) {
  for (int i = 0; i < 4; i++)
    if (recorders[i]) {
      char *text =
          bindings[i].key ? gtk_accelerator_get_label(bindings[i].key, bindings[i].mods) : g_strdup("未设置");
      gtk_button_set_label(GTK_BUTTON(recorders[i]), recording == i ? "按下快捷键…" : text);
      g_free(text);
    }
}
static void begin(GtkButton *button, gpointer data) {
  (void)button;
  recording = GPOINTER_TO_INT(data);
  refresh();
  gtk_label_set_text(GTK_LABEL(status), "按下按键；Esc 取消，Delete 清除。仅在选中贴图时生效。");
}
static gboolean record_key(GtkWidget *widget, GdkEventKey *event, gpointer data) {
  (void)widget;
  (void)data;
  if (recording < 0)
    return FALSE;
  if (event->keyval == GDK_KEY_Escape) {
    recording = -1;
    refresh();
    return TRUE;
  }
  if (event->keyval >= GDK_KEY_Shift_L && event->keyval <= GDK_KEY_Hyper_R)
    return TRUE;
  Binding value = normalize(event->keyval, event->state);
  if (event->keyval == GDK_KEY_Delete || event->keyval == GDK_KEY_BackSpace)
    value = (Binding){0, 0};
  for (int i = 0; i < 4; i++)
    if (i != recording && value.key && same(value, bindings[i])) {
      gtk_label_set_text(GTK_LABEL(status), "这个按键已用于另一项贴图操作。");
      return TRUE;
    }
  Binding previous = bindings[recording];
  bindings[recording] = value;
  if (!save()) {
    bindings[recording] = previous;
    gtk_label_set_text(GTK_LABEL(status), "无法保存，请检查配置目录。");
  } else
    gtk_label_set_text(GTK_LABEL(status), "贴图按键已保存。");
  recording = -1;
  refresh();
  return TRUE;
}
static void reset_keys(GtkButton *button, gpointer data) {
  (void)button;
  (void)data;
  Binding previous[4];
  memcpy(previous, bindings, sizeof(bindings));
  memcpy(bindings, defaults, sizeof(bindings));
  if (!save())
    memcpy(bindings, previous, sizeof(bindings));
  recording = -1;
  refresh();
}
static gboolean cancel_keys(GtkWidget *widget, GdkEventFocus *event, gpointer data) {
  (void)widget;
  (void)event;
  (void)data;
  recording = -1;
  refresh();
  return FALSE;
}
static void prefs_destroy(GtkWidget *widget, gpointer data) {
  (void)widget;
  (void)data;
  memset(recorders, 0, sizeof(recorders));
  status = NULL;
  recording = -1;
}
GtkWidget *mc_linux_pin_preferences(void) {
  GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
  gtk_container_set_border_width(GTK_CONTAINER(box), 20);
  GtkWidget *grid = gtk_grid_new();
  gtk_grid_set_column_spacing(GTK_GRID(grid), 12);
  gtk_grid_set_row_spacing(GTK_GRID(grid), 10);
  for (int i = 0; i < 4; i++) {
    gtk_grid_attach(GTK_GRID(grid), gtk_label_new(names[i]), 0, i, 1, 1);
    recorders[i] = gtk_button_new();
    gtk_widget_set_hexpand(recorders[i], TRUE);
    g_signal_connect(recorders[i], "clicked", G_CALLBACK(begin), GINT_TO_POINTER(i));
    g_signal_connect(recorders[i], "key-press-event", G_CALLBACK(record_key), NULL);
    g_signal_connect(recorders[i], "focus-out-event", G_CALLBACK(cancel_keys), NULL);
    gtk_grid_attach(GTK_GRID(grid), recorders[i], 1, i, 1, 1);
  }
  gtk_box_pack_start(GTK_BOX(box), grid, FALSE, FALSE, 0);
  GtkWidget *button = gtk_button_new_with_label("恢复默认");
  g_signal_connect(button, "clicked", G_CALLBACK(reset_keys), NULL);
  gtk_box_pack_start(GTK_BOX(box), button, FALSE, FALSE, 0);
  status = gtk_label_new("单击贴图选中，拖动移动。Esc 取消选中，Delete 关闭。\nWayland "
                         "下置顶、跨工作区和透明度由桌面合成器决定。");
  gtk_label_set_line_wrap(GTK_LABEL(status), TRUE);
  gtk_box_pack_start(GTK_BOX(box), status, FALSE, FALSE, 0);
  g_signal_connect(box, "destroy", G_CALLBACK(prefs_destroy), NULL);
  refresh();
  return box;
}
gboolean mc_linux_pin_smoke(void) {
  GtkWidget *preferences = mc_linux_pin_preferences();
  g_object_ref_sink(preferences);
  begin(NULL, GINT_TO_POINTER(0));
  GdkEventKey config_event = {0};
  config_event.keyval = GDK_KEY_k;
  config_event.state = GDK_CONTROL_MASK | GDK_MOD1_MASK;
  gboolean saved = record_key(NULL, &config_event, NULL) && bindings[0].key == GDK_KEY_k;
  Binding previous = bindings[1];
  begin(NULL, GINT_TO_POINTER(1));
  saved = record_key(NULL, &config_event, NULL) && same(bindings[1], previous) && saved;
  GKeyFile *file = g_key_file_new();
  gsize count = 0;
  saved = g_key_file_load_from_file(file, settings_path, G_KEY_FILE_NONE, NULL) && saved;
  int *value = g_key_file_get_integer_list(file, "Pins", "key0", &count, NULL);
  saved = value && count == 2 && value[0] == GDK_KEY_k && saved;
  g_free(value);
  g_key_file_unref(file);
  reset_keys(NULL, NULL);
  saved = memcmp(bindings, defaults, sizeof(bindings)) == 0 && saved;
  gtk_widget_destroy(preferences);
  g_object_unref(preferences);
  GdkPixbuf *image = gdk_pixbuf_new(GDK_COLORSPACE_RGB, FALSE, 8, 120, 80);
  gdk_pixbuf_fill(image, 0xAA7744FF);
  mc_linux_pin_image(image);
  g_object_unref(image);
  if (!pins)
    return FALSE;
  Pin *pin = pins->data;
  double old = pin->scale;
  GdkEventKey event = {0};
  event.keyval = GDK_KEY_equal;
  pin->selected = TRUE;
  gboolean ok = key(pin->window, &event, pin) && pin->scale > old;
  event.state = GDK_CONTROL_MASK;
  event.keyval = GDK_KEY_minus;
  ok = key(pin->window, &event, pin) && pin->opacity < 1 && ok;
  ok = gdk_pixbuf_get_width(pin->image) == 120 && ok;
  for (int i = 0; i < 20; i++)
    apply(pin, 3);
  ok = pin->opacity >= .1 && ok;
  event.state = 0;
  event.keyval = GDK_KEY_Escape;
  key(pin->window, &event, pin);
  old = pin->scale;
  event.keyval = GDK_KEY_plus;
  ok = !key(pin->window, &event, pin) && pin->scale == old && ok;
  mc_linux_pins_hide(TRUE);
  ok = !gtk_widget_get_visible(pin->window) && ok;
  mc_linux_pins_hide(FALSE);
  mc_linux_pins_close();
  return ok && pins == NULL && saved;
}
