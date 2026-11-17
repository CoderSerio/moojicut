#include "pinning.h"
#include "native/shared/feature_runtime.h"
#include "native/shared/pin_policy.h"
#include "moonbit.h"
#include <dlfcn.h>
#include <gdk/gdkx.h>
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
  gboolean selected, hidden, passthrough;
  int resize_handle, resize_x, resize_y;
  double resize_mouse_x, resize_mouse_y, resize_scale;
} Pin;
static GtkApplication *application;
static GSList *pins;
static char *settings_path;
static Binding bindings[6];
static const Binding defaults[6] = {{GDK_KEY_plus, 0},
                                    {GDK_KEY_minus, 0},
                                    {GDK_KEY_plus, GDK_CONTROL_MASK},
                                    {GDK_KEY_minus, GDK_CONTROL_MASK},
                                    {GDK_KEY_h, GDK_CONTROL_MASK | GDK_SHIFT_MASK},
                                    {GDK_KEY_p, GDK_CONTROL_MASK | GDK_SHIFT_MASK}};
static const char *names[] = {"放大贴图",     "缩小贴图",        "增加不透明度",
                              "降低不透明度", "隐藏 / 恢复贴图", "切换鼠标穿透"};
static GtkWidget *recorders[6], *status, *preferences_box;
static int recording = -1;
static int feature_state;

static gboolean capture_hidden, global_ready[2], global_down[2], filter_added;
static void *xlib;
static int (*grab_key)(Display *, int, unsigned, Window, int, int, int);
static int (*ungrab_key)(Display *, int, unsigned, Window);
static KeyCode (*keysym_keycode)(Display *, KeySym);
static void visibility_action(void);
static void passthrough_action(void);
static GdkFilterReturn global_filter(GdkXEvent *native, GdkEvent *event, gpointer data);
static gboolean record_key(GtkWidget *widget, GdkEventKey *event, gpointer data);
static void refresh(void);
static void copy(GtkMenuItem *item, gpointer data);
static void end_resize(Pin *pin) {
  pin->resize_handle = 0;
  if (gtk_widget_has_grab(pin->canvas)) gtk_grab_remove(pin->canvas);
}
gboolean mc_linux_pins_enabled(void) { return feature_can_invoke(feature_state) == 1; }
static unsigned x_mods(GdkModifierType mods) {
  return ((mods & GDK_CONTROL_MASK) ? ControlMask : 0) | ((mods & GDK_SHIFT_MASK) ? ShiftMask : 0) |
         ((mods & GDK_MOD1_MASK) ? Mod1Mask : 0) | ((mods & GDK_SUPER_MASK) ? Mod4Mask : 0);
}
static gboolean x11_available(void) {
  if (!GDK_IS_X11_DISPLAY(gdk_display_get_default()))
    return FALSE;
  if (!xlib) {
    xlib = dlopen("libX11.so.6", RTLD_NOW | RTLD_LOCAL);
    if (xlib) {
      grab_key = dlsym(xlib, "XGrabKey");
      ungrab_key = dlsym(xlib, "XUngrabKey");
      keysym_keycode = dlsym(xlib, "XKeysymToKeycode");
      Bool (*detectable_repeat)(Display *, Bool, Bool *) = dlsym(xlib, "XkbSetDetectableAutoRepeat");
      if (detectable_repeat) {
        Bool supported = FALSE;
        detectable_repeat(gdk_x11_display_get_xdisplay(gdk_display_get_default()), True, &supported);
      }
    }
  }
  return grab_key && ungrab_key && keysym_keycode;
}
static void release_global(Binding value) {
  if (!x11_available() || !value.key)
    return;
  Display *display = gdk_x11_display_get_xdisplay(gdk_display_get_default());
  KeyCode code = keysym_keycode(display, value.key);
  unsigned locks[] = {0, LockMask, Mod2Mask, LockMask | Mod2Mask};
  for (int i = 0; i < 4; i++)
    ungrab_key(display, code, x_mods(value.mods) | locks[i],
               gdk_x11_window_get_xid(gdk_get_default_root_window()));
  gdk_display_sync(gdk_display_get_default());
}
static gboolean register_global(Binding value) {
  if (!x11_available() || !value.key)
    return FALSE;
  Display *display = gdk_x11_display_get_xdisplay(gdk_display_get_default());
  KeyCode code = keysym_keycode(display, value.key);
  if (!code)
    return FALSE;
  unsigned locks[] = {0, LockMask, Mod2Mask, LockMask | Mod2Mask};
  gdk_x11_display_error_trap_push(gdk_display_get_default());
  for (int i = 0; i < 4; i++)
    grab_key(display, code, x_mods(value.mods) | locks[i],
             gdk_x11_window_get_xid(gdk_get_default_root_window()), FALSE, GrabModeAsync, GrabModeAsync);
  if (gdk_x11_display_error_trap_pop(gdk_display_get_default())) {
    release_global(value);
    return FALSE;
  }
  return TRUE;
}
static Pin *selected_pin(void) {
  for (GSList *n = pins; n; n = n->next) {
    Pin *p = n->data;
    if (p->selected && p->passthrough)
      return p;
  }
  for (GSList *n = pins; n; n = n->next) {
    Pin *p = n->data;
    if (p->selected)
      return p;
  }
  return NULL;
}
static void show_pin(Pin *pin) {
  if (pin->hidden || capture_hidden) end_resize(pin);
  if (pin->hidden || capture_hidden)
    gtk_widget_hide(pin->window);
  else
    gtk_widget_show(pin->window);
}
static gboolean set_passthrough(Pin *pin, gboolean active) {
  if (active && !global_ready[1]) {
    if (status)
      gtk_label_set_text(GTK_LABEL(status), "无法注册全局恢复键，已保持可点击。Wayland 暂不支持鼠标穿透。");
    return FALSE;
  }
  pin->passthrough = active;
  end_resize(pin);
  pin->selected = TRUE;
  gtk_window_set_accept_focus(GTK_WINDOW(pin->window), !active);
  cairo_region_t *empty = active ? cairo_region_create() : NULL;
  gtk_widget_input_shape_combine_region(pin->window, empty);
  if (empty)
    cairo_region_destroy(empty);
  if (!active && !pin->hidden && !capture_hidden)
    gtk_window_present(GTK_WINDOW(pin->window));
  gtk_widget_queue_draw(pin->canvas);
  return TRUE;
}
static void visibility_action(void) {
  Pin *selected = selected_pin();
  gboolean hidden = FALSE;
  for (GSList *n = pins; n; n = n->next)
    hidden = hidden || ((Pin *)n->data)->hidden;
  int action = pin_visibility_action(MC_PIN_LINUX, selected != NULL, selected && selected->hidden,
      selected && selected->passthrough, hidden, global_ready[0]);
  if (action == MC_PIN_VISIBILITY_NONE || action == MC_PIN_RECOVERY_UNAVAILABLE) return;
  if (action == MC_PIN_SHOW_SELECTED || action == MC_PIN_HIDE_SELECTED) {
    selected->hidden = pin_hidden_after(MC_PIN_LINUX, action, selected->hidden, selected->passthrough, 1);
    if (selected->hidden)
      selected->selected = FALSE;
    show_pin(selected);
    return;
  }
  for (GSList *n = pins; n; n = n->next) {
    Pin *p = n->data;
    if (p->passthrough)
      continue;
    p->hidden = pin_hidden_after(MC_PIN_LINUX, action, p->hidden, p->passthrough, 0);
    show_pin(p);
  }
}
void mc_linux_pins_restore(void) {
  for (GSList *n = pins; n; n = n->next) {
    Pin *p = n->data;
    p->hidden = pin_hidden_after(MC_PIN_LINUX, MC_PIN_RESTORE_HIDDEN, p->hidden, p->passthrough, 0);
    show_pin(p);
  }
}
static void passthrough_action(void) {
  Pin *p = selected_pin();
  if (p)
    set_passthrough(p, !p->passthrough);
}
static GdkFilterReturn global_filter(GdkXEvent *native, GdkEvent *event, gpointer data) {
  (void)event;
  (void)data;
  if (!mc_linux_pins_enabled())
    return GDK_FILTER_CONTINUE;
  XEvent *x = native;
  if (x->type != KeyPress && x->type != KeyRelease)
    return GDK_FILTER_CONTINUE;
  if (x->type == KeyRelease) {
    Display *display = gdk_x11_display_get_xdisplay(gdk_display_get_default());
    for (int i = 0; i < 2; i++)
      if (global_ready[i] && x->xkey.keycode == keysym_keycode(display, bindings[i + 4].key)) {
        global_down[i] = FALSE;
        return GDK_FILTER_REMOVE;
      }
    return GDK_FILTER_CONTINUE;
  }
  Display *display = gdk_x11_display_get_xdisplay(gdk_display_get_default());
  unsigned state = x->xkey.state & ~(LockMask | Mod2Mask);
  for (int i = 0; i < 2; i++)
    if (global_ready[i] && x->xkey.keycode == keysym_keycode(display, bindings[i + 4].key) &&
        state == x_mods(bindings[i + 4].mods)) {
      if (global_down[i])
        return GDK_FILTER_REMOVE;
      global_down[i] = TRUE;
      if (recording >= 0) {
        GdkEventKey key_event = {0};
        key_event.keyval = bindings[i + 4].key;
        key_event.state = bindings[i + 4].mods;
        record_key(NULL, &key_event, NULL);
        return GDK_FILTER_REMOVE;
      }
      if (i == 0)
        visibility_action();
      else
        passthrough_action();
      return GDK_FILTER_REMOVE;
    }
  return GDK_FILTER_CONTINUE;
}
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
  for (int i = 0; i < 6; i++) {
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
  mc_linux_pins_set_enabled(FALSE);
  application = app;
  g_free(settings_path);
  settings_path = g_strconcat(path, ".pins", NULL);
  memcpy(bindings, defaults, sizeof(bindings));
  GKeyFile *file = g_key_file_new();
  if (g_key_file_load_from_file(file, settings_path, G_KEY_FILE_NONE, NULL)) {
    for (int i = 0; i < 6; i++) {
      char key[8];
      g_snprintf(key, sizeof(key), "key%d", i);
      gsize n = 0;
      int *v = g_key_file_get_integer_list(file, "Pins", key, &n, NULL);
      if (v && n == 2)
        bindings[i] = normalize((guint)v[0], (GdkModifierType)v[1]);
      g_free(v);
    }
    for (int i = 4; i < 6; i++)
      if (bindings[i].key && !(bindings[i].mods & (GDK_CONTROL_MASK | GDK_MOD1_MASK | GDK_SUPER_MASK)))
        bindings[i] = defaults[i];
    for (int i = 0; i < 6; i++)
      for (int j = 0; j < i; j++)
        if (bindings[i].key && same(bindings[i], bindings[j]))
          memcpy(bindings, defaults, sizeof(bindings));
  }
  g_key_file_unref(file);
}
void mc_linux_pins_set_enabled(gboolean enabled) {
  if (enabled == mc_linux_pins_enabled())
    return;
  if (!enabled) {
    feature_state = feature_transition(feature_state, MC_FEATURE_REQUEST_DISABLE);
    recording = -1;
    /* Restore input before removing its recovery key. Closing the feature is
     * stronger than the interactive close-all command, which protects pins. */
    mc_linux_pins_restore_input();
    mc_linux_pins_close();
    for (int i = 0; i < 2; i++) {
      if (global_ready[i])
        release_global(bindings[i + 4]);
      global_ready[i] = global_down[i] = FALSE;
    }
    if (filter_added) {
      gdk_window_remove_filter(NULL, global_filter, NULL);
      filter_added = FALSE;
    }
    capture_hidden = FALSE;
    feature_state = feature_transition(feature_state, MC_FEATURE_CLEANUP_FINISHED);
  } else {
    feature_state = feature_transition(feature_state, MC_FEATURE_ENABLE);
    if (x11_available()) {
      for (int i = 0; i < 2; i++)
        global_ready[i] = register_global(bindings[i + 4]);
      if (!filter_added) {
        gdk_window_add_filter(NULL, global_filter, NULL);
        filter_added = TRUE;
      }
    }
  }
  if (preferences_box)
    gtk_widget_set_sensitive(preferences_box, mc_linux_pins_enabled());
  refresh();
}
static void resize_pin(Pin *pin, double scale) {
  GdkMonitor *monitor = gdk_display_get_monitor_at_window(gtk_widget_get_display(pin->window),
                                                          gtk_widget_get_window(pin->window));
  GdkRectangle area = {0, 0, 1920, 1080};
  if (monitor)
    gdk_monitor_get_workarea(monitor, &area);
  double resolved = pin_scale(MC_PIN_LINUX, scale, gdk_pixbuf_get_width(pin->image), gdk_pixbuf_get_height(pin->image), area.width, area.height);
  if (resolved <= 0) return;
  pin->scale = resolved;
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
static gboolean delete_request(GtkWidget *widget, GdkEvent *event, gpointer data) {
  (void)widget;
  (void)event;
  return ((Pin *)data)->passthrough;
}
static void destroyed(GtkWidget *widget, gpointer data) {
  (void)widget;
  Pin *pin = data;
  end_resize(pin);
  pins = g_slist_remove(pins, pin);
  g_object_unref(pin->image);
  g_free(pin);
}
static gboolean focus(GtkWidget *widget, GdkEventFocus *event, gpointer data) {
  (void)widget;
  Pin *pin = data;
  if (event->in) {
    for (GSList *n = pins; n; n = n->next) {
      Pin *p = n->data;
      if (p != pin && !p->passthrough) {
        p->selected = FALSE;
        gtk_widget_queue_draw(p->canvas);
      }
    }
    pin->selected = TRUE;
  } else {
    end_resize(pin);
    if (!pin->passthrough) pin->selected = FALSE;
  }
  gtk_widget_queue_draw(pin->canvas);
  return FALSE;
}
static void apply(Pin *pin, int action) {
  if (pin->passthrough)
    return;
  if (action < 2)
    resize_pin(pin, pin_zoom_step(pin->scale, action == 0 ? 1 : -1));
  else {
    pin->opacity = pin_opacity(MC_PIN_LINUX, pin->opacity, action == 2 ? 1 : -1);
    gtk_widget_set_opacity(pin->window, pin->opacity);
  }
}
static gboolean key(GtkWidget *widget, GdkEventKey *event, gpointer data) {
  (void)widget;
  Pin *pin = data;
  if (!pin->selected)
    return FALSE;
  Binding value = normalize(event->keyval, event->state);
  if (value.key == GDK_KEY_c && value.mods == GDK_CONTROL_MASK) {
    if (pin->passthrough || pin->hidden || capture_hidden || !mc_linux_pins_enabled()) return FALSE;
    copy(NULL, pin);
    return TRUE;
  }
  if (pin->hidden || capture_hidden || !mc_linux_pins_enabled()) return FALSE;
  if (pin->passthrough) {
    if (bindings[5].key && same(value, bindings[5]))
      set_passthrough(pin, FALSE);
    return TRUE;
  }
  if (event->keyval == GDK_KEY_Escape || event->keyval == GDK_KEY_Delete) {
    gtk_widget_destroy(pin->window);
    return TRUE;
  }
  for (int i = 0; i < 6; i++)
    if (bindings[i].key && same(value, bindings[i])) {
      if (i < 4)
        apply(pin, i);
      else if (i == 4)
        visibility_action();
      else
        passthrough_action();
      return TRUE;
    }
  return FALSE;
}
static void copy(GtkMenuItem *item, gpointer data) {
  (void)item;
  Pin *pin = data;
  if (pin->passthrough || pin->hidden || capture_hidden || !mc_linux_pins_enabled())
    return;
  GtkClipboard *clip = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  gtk_clipboard_set_image(clip, pin->image);
  gtk_clipboard_set_can_store(clip, NULL, 0);
  gtk_clipboard_store(clip);
}
static void reset(GtkMenuItem *item, gpointer data) {
  (void)item;
  Pin *pin = data;
  if (pin->passthrough)
    return;
  pin->opacity = 1;
  gtk_widget_set_opacity(pin->window, 1);
  resize_pin(pin, 1);
}
static void close_pin(GtkMenuItem *item, gpointer data) {
  (void)item;
  Pin *pin = data;
  if (!pin->passthrough)
    gtk_widget_destroy(pin->window);
}
static gboolean press(GtkWidget *widget, GdkEventButton *event, gpointer data) {
  (void)widget;
  Pin *pin = data;
  if (pin->passthrough || pin->hidden || capture_hidden || !mc_linux_pins_enabled())
    return TRUE;
  if (event->button == 1 && event->type == GDK_2BUTTON_PRESS) {
    gtk_widget_destroy(pin->window);
    return TRUE;
  }
  for (GSList *n = pins; n; n = n->next) {
    Pin *p = n->data;
    if (p != pin && !p->passthrough)
      p->selected = FALSE;
  }
  pin->selected = TRUE;
  gtk_window_present(GTK_WINDOW(pin->window));
  gtk_widget_queue_draw(pin->canvas);
  if (event->button == 1) {
    pin->resize_handle = pin_hit_handle(gtk_widget_get_allocated_width(pin->canvas),
        gtk_widget_get_allocated_height(pin->canvas), event->x, event->y, 6);
    if (pin->resize_handle) {
      gtk_window_get_position(GTK_WINDOW(pin->window), &pin->resize_x, &pin->resize_y);
      pin->resize_mouse_x = event->x_root; pin->resize_mouse_y = event->y_root; pin->resize_scale = pin->scale;
      gtk_grab_add(pin->canvas);
      return TRUE;
    }
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
static gboolean motion(GtkWidget *widget, GdkEventMotion *event, gpointer data) {
  (void)widget; Pin *pin = data;
  if (pin->passthrough || pin->hidden || capture_hidden || !mc_linux_pins_enabled()) { end_resize(pin); return FALSE; }
  if (pin->resize_handle) {
    GdkMonitor *monitor = gdk_display_get_monitor_at_window(gtk_widget_get_display(pin->window), gtk_widget_get_window(pin->window));
    GdkRectangle area = {0, 0, 1920, 1080};
    if (monitor) gdk_monitor_get_workarea(monitor, &area);
    double *frame = pin_resize_frame(MC_PIN_LINUX, pin->resize_x, pin->resize_y,
        gdk_pixbuf_get_width(pin->image), gdk_pixbuf_get_height(pin->image), pin->resize_scale, pin->resize_handle,
        event->x_root - pin->resize_mouse_x, event->y_root - pin->resize_mouse_y, area.x, area.y, area.width, area.height);
    if (frame[4] > 0) {
      pin->scale = frame[4];
      int w = MAX(1, (int)round(frame[2])), h = MAX(1, (int)round(frame[3]));
      gtk_widget_set_size_request(pin->canvas, w, h); gtk_window_resize(GTK_WINDOW(pin->window), w, h);
      gtk_window_move(GTK_WINDOW(pin->window), (int)round(frame[0]), (int)round(frame[1]));
      gtk_widget_queue_draw(pin->canvas);
    }
    moonbit_decref(frame);
  } else {
    int edge = pin_hit_handle(gtk_widget_get_allocated_width(pin->canvas), gtk_widget_get_allocated_height(pin->canvas), event->x, event->y, 6);
    const char *name = edge == 5 || edge == 10 ? "nwse-resize" : edge == 6 || edge == 9 ? "nesw-resize" :
        edge & 3 ? "ew-resize" : edge & 12 ? "ns-resize" : "grab";
    GdkCursor *cursor = gdk_cursor_new_from_name(gtk_widget_get_display(pin->canvas), name);
    gdk_window_set_cursor(gtk_widget_get_window(pin->canvas), cursor);
    if (cursor) g_object_unref(cursor);
  }
  return TRUE;
}
static gboolean release(GtkWidget *widget, GdkEventButton *event, gpointer data) {
  (void)widget; if (event->button != 1) return FALSE;
  Pin *pin = data; gboolean resizing = pin->resize_handle != 0; end_resize(pin); return resizing;
}
static gboolean grab_broken(GtkWidget *widget, GdkEventGrabBroken *event, gpointer data) {
  (void)widget; (void)event; end_resize(data); return FALSE;
}
static gboolean scroll(GtkWidget *widget, GdkEventScroll *event, gpointer data) {
  (void)widget; Pin *pin = data;
  if (pin->passthrough || pin->hidden || capture_hidden || pin->resize_handle || !mc_linux_pins_enabled()) return FALSE;
  double steps = event->direction == GDK_SCROLL_UP ? 1 : event->direction == GDK_SCROLL_DOWN ? -1 : 0;
  if (event->direction == GDK_SCROLL_SMOOTH) { double x = 0, y = 0;
    if (gdk_event_get_scroll_deltas((GdkEvent *)event, &x, &y)) steps = -y; }
  if (!steps) return FALSE;
  double requested = pin_scroll_scale(pin->scale, steps);
  if (requested <= 0) return FALSE;
  resize_pin(pin, requested); return TRUE;
}
void mc_linux_pin_image_at(GdkPixbuf *image, const GdkRectangle *bounds) {
  if (!mc_linux_pins_enabled())
    return;
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
  gtk_widget_add_events(pin->canvas, GDK_BUTTON_PRESS_MASK | GDK_BUTTON_RELEASE_MASK | GDK_POINTER_MOTION_MASK |
      GDK_SCROLL_MASK | GDK_SMOOTH_SCROLL_MASK);
  gtk_container_add(GTK_CONTAINER(pin->window), pin->canvas);
  g_signal_connect(pin->canvas, "draw", G_CALLBACK(draw), pin);
  g_signal_connect(pin->canvas, "button-press-event", G_CALLBACK(press), pin);
  g_signal_connect(pin->canvas, "button-release-event", G_CALLBACK(release), pin);
  g_signal_connect(pin->canvas, "motion-notify-event", G_CALLBACK(motion), pin);
  g_signal_connect(pin->canvas, "grab-broken-event", G_CALLBACK(grab_broken), pin);
  g_signal_connect(pin->canvas, "scroll-event", G_CALLBACK(scroll), pin);
  g_signal_connect(pin->window, "key-press-event", G_CALLBACK(key), pin);
  g_signal_connect(pin->window, "focus-in-event", G_CALLBACK(focus), pin);
  g_signal_connect(pin->window, "focus-out-event", G_CALLBACK(focus), pin);
  g_signal_connect(pin->window, "destroy", G_CALLBACK(destroyed), pin);
  g_signal_connect(pin->window, "delete-event", G_CALLBACK(delete_request), pin);
  pins = g_slist_prepend(pins, pin);
  gtk_widget_realize(pin->window);
  if (bounds) {
    pin->scale = (double)MAX(1, bounds->width) / gdk_pixbuf_get_width(image);
    gtk_widget_set_size_request(pin->canvas, MAX(1, bounds->width), MAX(1, bounds->height));
    gtk_window_resize(GTK_WINDOW(pin->window), MAX(1, bounds->width), MAX(1, bounds->height));
  } else
    resize_pin(pin, 1);
  if (bounds)
    gtk_window_move(GTK_WINDOW(pin->window), bounds->x, bounds->y);
  gtk_widget_show_all(pin->window);
  if (bounds)
    gtk_window_move(GTK_WINDOW(pin->window), bounds->x, bounds->y);
  gtk_window_present(GTK_WINDOW(pin->window));
}
void mc_linux_pin_image(GdkPixbuf *image) {
  mc_linux_pin_image_at(image, NULL);
}
void mc_linux_pins_hide(gboolean hidden) {
  capture_hidden = hidden;
  for (GSList *n = pins; n; n = n->next)
    show_pin(n->data);
}
void mc_linux_pins_close_interactive(void) {
  GSList *node = pins;
  while (node) {
    Pin *pin = node->data;
    node = node->next;
    if (!pin->passthrough)
      gtk_widget_destroy(pin->window);
  }
}
void mc_linux_pins_restore_input(void) {
  for (GSList *n = pins; n; n = n->next) {
    Pin *p = n->data;
    if (p->passthrough)
      set_passthrough(p, FALSE);
  }
}
/* Application shutdown owns forced teardown, including pass-through windows. */
void mc_linux_pins_close(void) {
  while (pins)
    gtk_widget_destroy(((Pin *)pins->data)->window);
}
static void refresh(void) {
  for (int i = 0; i < 6; i++)
    if (recorders[i]) {
      char *text =
          bindings[i].key ? gtk_accelerator_get_label(bindings[i].key, bindings[i].mods) : g_strdup("未设置");
      gtk_button_set_label(GTK_BUTTON(recorders[i]), recording == i ? "按下快捷键…" : text);
      g_free(text);
    }
}
static void begin(GtkButton *button, gpointer data) {
  (void)button;
  if (!mc_linux_pins_enabled())
    return;
  recording = GPOINTER_TO_INT(data);
  refresh();
  gtk_label_set_text(GTK_LABEL(status),
                     "按下按键；Esc 取消，Delete 清除。隐藏/恢复与穿透在 X11 注册为全局按键。");
}
static gboolean record_key(GtkWidget *widget, GdkEventKey *event, gpointer data) {
  (void)widget;
  (void)data;
  if (!mc_linux_pins_enabled() || recording < 0)
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
  for (int i = 0; i < 6; i++)
    if (i != recording && value.key && same(value, bindings[i])) {
      gtk_label_set_text(GTK_LABEL(status), "这个按键已用于另一项贴图操作。");
      return TRUE;
    }
  if (recording >= 4 && value.key && !(value.mods & (GDK_CONTROL_MASK | GDK_MOD1_MASK | GDK_SUPER_MASK))) {
    gtk_label_set_text(GTK_LABEL(status), "全局恢复键需要 Ctrl、Alt 或 Super 修饰键。");
    return TRUE;
  }
  Binding previous = bindings[recording];
  gboolean was_global = recording >= 4 && global_ready[recording - 4];
  if (recording == 5) {
    for (GSList *n = pins; n; n = n->next) {
      Pin *p = n->data;
      if (p->passthrough)
        set_passthrough(p, FALSE);
    }
  }
  if (was_global)
    release_global(previous);
  bindings[recording] = value;
  if (recording >= 4 && x11_available()) {
    global_ready[recording - 4] = value.key ? register_global(value) : FALSE;
    if (value.key && !global_ready[recording - 4]) {
      bindings[recording] = previous;
      global_ready[recording - 4] = was_global && register_global(previous);
      gtk_label_set_text(GTK_LABEL(status), "该全局按键被其他程序占用，原设置已保留。");
      return TRUE;
    }
  }
  if (!save()) {
    if (recording >= 4 && global_ready[recording - 4])
      release_global(value);
    bindings[recording] = previous;
    if (recording >= 4)
      global_ready[recording - 4] = was_global && register_global(previous);
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
  if (!mc_linux_pins_enabled())
    return;
  Binding previous[6];
  memcpy(previous, bindings, sizeof(bindings));
  for (GSList *n = pins; n; n = n->next) {
    Pin *p = n->data;
    if (p->passthrough)
      set_passthrough(p, FALSE);
  }
  for (int i = 0; i < 2; i++)
    if (global_ready[i])
      release_global(bindings[i + 4]);
  memcpy(bindings, defaults, sizeof(bindings));
  gboolean ok = TRUE;
  for (int i = 0; i < 2; i++) {
    global_ready[i] = register_global(bindings[i + 4]);
    if (x11_available() && !global_ready[i])
      ok = FALSE;
  }
  if (!ok || !save()) {
    for (int i = 0; i < 2; i++)
      if (global_ready[i])
        release_global(bindings[i + 4]);
    memcpy(bindings, previous, sizeof(bindings));
    for (int i = 0; i < 2; i++)
      global_ready[i] = register_global(bindings[i + 4]);
  }
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
  preferences_box = NULL;
  recording = -1;
}
GtkWidget *mc_linux_pin_preferences(void) {
  GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
  preferences_box = box;
  gtk_widget_set_sensitive(box, mc_linux_pins_enabled());
  gtk_container_set_border_width(GTK_CONTAINER(box), 20);
  GtkWidget *grid = gtk_grid_new();
  gtk_grid_set_column_spacing(GTK_GRID(grid), 12);
  gtk_grid_set_row_spacing(GTK_GRID(grid), 10);
  for (int i = 0; i < 6; i++) {
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
  status = gtk_label_new(
      "单击选中，拖动移动；双击或 Esc 关闭。穿透时仅恢复键有效。\n隐藏后也可从托盘恢复。Wayland "
      "暂不支持鼠标穿透；X11 需成功注册全局恢复键。");
  gtk_label_set_line_wrap(GTK_LABEL(status), TRUE);
  gtk_box_pack_start(GTK_BOX(box), status, FALSE, FALSE, 0);
  g_signal_connect(box, "destroy", G_CALLBACK(prefs_destroy), NULL);
  refresh();
  return box;
}
static gboolean smoke_timer(gpointer data) {
  *(gboolean *)data = TRUE;
  return G_SOURCE_REMOVE;
}
static gboolean smoke_recover_key(Pin *pin) {
  if (g_strcmp0(g_getenv("MOOJICUT_X11_INPUT_SMOKE"), "1") != 0) {
    XEvent event = {0};
    event.xkey.type = KeyPress;
    event.xkey.keycode =
        keysym_keycode(gdk_x11_display_get_xdisplay(gdk_display_get_default()), bindings[5].key);
    event.xkey.state = x_mods(bindings[5].mods);
    gboolean result = global_filter(&event, NULL, NULL) == GDK_FILTER_REMOVE && !pin->passthrough;
    global_down[1] = FALSE;
    return result;
  }
  void *xtest = dlopen("libXtst.so.6", RTLD_NOW | RTLD_LOCAL);
  if (!xtest)
    return FALSE;
  int (*inject)(Display *, unsigned, int, unsigned long) = dlsym(xtest, "XTestFakeKeyEvent");
  if (!inject) {
    dlclose(xtest);
    return FALSE;
  }
  Display *display = gdk_x11_display_get_xdisplay(gdk_display_get_default());
  gdk_window_focus(gdk_get_default_root_window(), GDK_CURRENT_TIME);
  KeyCode control = keysym_keycode(display, GDK_KEY_Control_L),
          shift = keysym_keycode(display, GDK_KEY_Shift_L),
          keycode = keysym_keycode(display, bindings[5].key);
  inject(display, control, TRUE, 0);
  inject(display, shift, TRUE, 0);
  inject(display, keycode, TRUE, 0);
  inject(display, keycode, FALSE, 0);
  inject(display, shift, FALSE, 0);
  inject(display, control, FALSE, 0);
  gdk_display_sync(gdk_display_get_default());
  gboolean elapsed = FALSE;
  guint timer = g_timeout_add(150, smoke_timer, &elapsed);
  while (!elapsed && pin->passthrough)
    g_main_context_iteration(NULL, TRUE);
  if (!elapsed)
    g_source_remove(timer);
  dlclose(xtest);
  return !pin->passthrough;
}
static gboolean wait_pin_geometry(Pin *pin, int width, int height, gboolean position, int x, int y) {
  // GTK resize/layout runs in a later frame-clock phase. Draining only events
  // already pending can still leave the canvas at its pre-resize allocation.
  // Wait for the real allocation/configure result; never allocate it ourselves.
  gboolean expired = FALSE, ready = FALSE;
  guint timer = g_timeout_add(1000, smoke_timer, &expired);
  gdk_display_sync(gdk_display_get_default());
  while (!expired) {
    int actual_x = 0, actual_y = 0;
    gtk_window_get_position(GTK_WINDOW(pin->window), &actual_x, &actual_y);
    ready = gtk_widget_get_mapped(pin->canvas) &&
        gtk_widget_get_allocated_width(pin->canvas) == width &&
        gtk_widget_get_allocated_height(pin->canvas) == height &&
        (!position || (actual_x == x && actual_y == y));
    if (ready) break;
    g_main_context_iteration(NULL, TRUE);
  }
  if (!expired) g_source_remove(timer);
  if (!ready) {
    int actual_x = 0, actual_y = 0;
    gtk_window_get_position(GTK_WINDOW(pin->window), &actual_x, &actual_y);
    g_printerr("Linux pin geometry timed out: got %dx%d at %d,%d; expected %dx%d%s at %d,%d.\n",
        gtk_widget_get_allocated_width(pin->canvas), gtk_widget_get_allocated_height(pin->canvas),
        actual_x, actual_y, width, height, position ? " with position" : "", x, y);
  }
  return ready;
}
static gboolean pin_smoke_check(gboolean condition, const char *step, Pin *pin) {
  if (!condition)
    g_printerr("Linux pin interaction failed at %s: scale=%g, allocation=%dx%d, handle=%d, grab=%d.\n",
        step, pin->scale, gtk_widget_get_allocated_width(pin->canvas), gtk_widget_get_allocated_height(pin->canvas),
        pin->resize_handle, gtk_widget_has_grab(pin->canvas));
  return condition;
}
static gboolean pin_interaction_smoke(Pin *pin) {
  double start = pin->scale;
  GdkEventScroll wheel = {0}; wheel.type = GDK_SCROLL; wheel.direction = GDK_SCROLL_SMOOTH; wheel.delta_y = -.25;
  wheel.window = gtk_widget_get_window(pin->canvas);
  gboolean handled = FALSE;
  g_signal_emit_by_name(pin->canvas, "scroll-event", &wheel, &handled);
  gboolean ok = pin_smoke_check(handled && pin->scale > start && pin->scale < start * 1.1, "fractional wheel", pin);
  for (int i = 0; i < 3; i++) g_signal_emit_by_name(pin->canvas, "scroll-event", &wheel, &handled);
  ok = pin_smoke_check(fabs(pin->scale - start * 1.1) < .000001, "four fractional wheel deltas", pin) && ok;
  wheel.delta_y = 1; g_signal_emit_by_name(pin->canvas, "scroll-event", &wheel, &handled);
  ok = pin_smoke_check(fabs(pin->scale - start) < .000001, "reverse wheel", pin) && ok;
  ok = wait_pin_geometry(pin, 120, 80, FALSE, 0, 0) && ok;
  int x = 0, y = 0; gtk_window_get_position(GTK_WINDOW(pin->window), &x, &y);
  GdkEventButton down = {0}; down.type = GDK_BUTTON_PRESS; down.button = 1;
  down.window = gtk_widget_get_window(pin->canvas);
  down.x = gtk_widget_get_allocated_width(pin->canvas) - 1;
  down.y = gtk_widget_get_allocated_height(pin->canvas) / 2;
  down.x_root = x + down.x; down.y_root = y + down.y;
  g_signal_emit_by_name(pin->canvas, "button-press-event", &down, &handled);
  ok = pin_smoke_check(handled && pin->resize_handle == 2 && gtk_widget_has_grab(pin->canvas), "edge press/grab", pin) && ok;
  GdkEventMotion move = {0}; move.type = GDK_MOTION_NOTIFY; move.state = GDK_BUTTON1_MASK;
  move.window = gtk_widget_get_window(pin->canvas);
  move.x_root = down.x_root + 30; move.y_root = down.y_root;
  g_signal_emit_by_name(pin->canvas, "motion-notify-event", &move, &handled);
  GdkEventButton up = down; up.type = GDK_BUTTON_RELEASE;
  g_signal_emit_by_name(pin->canvas, "button-release-event", &up, &handled);
  ok = wait_pin_geometry(pin, 150, 100, x11_available(), x, y - 10) && ok;
  int next_x = 0, next_y = 0; gtk_window_get_position(GTK_WINDOW(pin->window), &next_x, &next_y);
  ok = pin_smoke_check(fabs(pin->scale - 1.25) < .000001 && gtk_widget_get_allocated_width(pin->canvas) == 150 &&
      gtk_widget_get_allocated_height(pin->canvas) == 100 && !pin->resize_handle && !gtk_widget_has_grab(pin->canvas),
      "edge resize/release", pin) && ok;
  if (x11_available()) ok = pin_smoke_check(next_x == x && next_y == y - 10, "anchored edge position", pin) && ok;
  down.x = 149; down.y = 50; down.x_root = next_x + down.x; down.y_root = next_y + down.y;
  g_signal_emit_by_name(pin->canvas, "button-press-event", &down, &handled);
  mc_linux_pins_hide(TRUE); mc_linux_pins_hide(FALSE);
  double frozen = pin->scale;
  g_signal_emit_by_name(pin->canvas, "motion-notify-event", &move, &handled);
  ok = pin_smoke_check(pin->scale == frozen && !pin->resize_handle && !gtk_widget_has_grab(pin->canvas),
      "hide cancels resize/grab", pin) && ok;
  pin->passthrough = TRUE;
  g_signal_emit_by_name(pin->canvas, "scroll-event", &wheel, &handled);
  ok = pin_smoke_check(!handled && pin->scale == frozen, "passthrough wheel guard", pin) && ok; pin->passthrough = FALSE;
  if (g_strcmp0(g_getenv("CI"), "true") == 0) {
    GdkEventKey event = {0}; event.type = GDK_KEY_PRESS; event.keyval = GDK_KEY_c; event.state = GDK_CONTROL_MASK;
    event.window = gtk_widget_get_window(pin->window);
    pin->selected = TRUE;
    g_signal_emit_by_name(pin->window, "key-press-event", &event, &handled);
    GtkClipboard *clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
    GdkPixbuf *copied = gtk_clipboard_wait_for_image(clipboard);
    ok = pin_smoke_check(handled && copied && gdk_pixbuf_get_width(copied) == gdk_pixbuf_get_width(pin->image) &&
        gdk_pixbuf_get_height(copied) == gdk_pixbuf_get_height(pin->image) &&
        memcmp(gdk_pixbuf_get_pixels(copied), gdk_pixbuf_get_pixels(pin->image), 3) == 0, "Ctrl+C source pixels", pin) && ok;
    if (copied) g_object_unref(copied);
    pin->selected = FALSE; g_signal_emit_by_name(pin->window, "key-press-event", &event, &handled);
    ok = pin_smoke_check(!handled, "unselected copy guard", pin) && ok;
    pin->selected = TRUE; pin->hidden = TRUE;
    g_signal_emit_by_name(pin->window, "key-press-event", &event, &handled);
    ok = pin_smoke_check(!handled, "hidden copy guard", pin) && ok;
    pin->hidden = FALSE; pin->passthrough = TRUE;
    g_signal_emit_by_name(pin->window, "key-press-event", &event, &handled);
    ok = pin_smoke_check(!handled, "passthrough copy guard", pin) && ok;
    pin->passthrough = FALSE;
  }
  resize_pin(pin, start); ok = wait_pin_geometry(pin, 120, 80, FALSE, 0, 0) && ok;
  g_print("Linux pin interaction smoke %s: smooth wheel, proportional edge resize, cancel/grab cleanup, local copy guards.\n", ok ? "passed" : "FAILED");
  return ok;
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
  GdkRectangle anchor = {140, 110, 120, 80};
  mc_linux_pin_image_at(image, &anchor);
  g_object_unref(image);
  if (!pins)
    return FALSE;
  Pin *pin = pins->data;
  gboolean ok = wait_pin_geometry(pin, anchor.width, anchor.height, x11_available(), anchor.x, anchor.y);
  gboolean interaction_ok = pin_interaction_smoke(pin);
  double old = pin->scale;
  GdkEventKey event = {0};
  event.keyval = GDK_KEY_equal;
  pin->selected = TRUE;
  ok = key(pin->window, &event, pin) && pin->scale > old && ok;
  event.state = GDK_CONTROL_MASK;
  event.keyval = GDK_KEY_minus;
  ok = key(pin->window, &event, pin) && pin->opacity < 1 && ok;
  double opacity = pin->opacity;
  visibility_action();
  ok = pin->hidden && !gtk_widget_get_visible(pin->window) && pin->opacity == opacity && ok;
  visibility_action();
  ok = !pin->hidden && gtk_widget_get_visible(pin->window) && pin->opacity == opacity && ok;
  pin->selected = FALSE;
  visibility_action();
  ok = pin->hidden && ok;
  mc_linux_pins_restore();
  ok = !pin->hidden && pin->opacity == opacity && ok;
  mc_linux_pins_hide(TRUE);
  ok = !gtk_widget_get_visible(pin->window) && !pin->hidden && ok;
  mc_linux_pins_hide(FALSE);
  gboolean recovery = global_ready[1];
  global_ready[1] = FALSE;
  ok = !set_passthrough(pin, TRUE) && !pin->passthrough && ok;
  global_ready[1] = recovery;
  if (x11_available()) {
    ok = global_ready[0] && global_ready[1] && set_passthrough(pin, TRUE) && ok;
    GdkEventFocus lost = {0};
    lost.in = FALSE;
    focus(pin->window, &lost, pin);
    ok = pin->selected && pin->passthrough && ok;
    old = pin->scale;
    opacity = pin->opacity;
    event.state = 0;
    event.keyval = GDK_KEY_Escape;
    key(pin->window, &event, pin);
    GdkEventButton mouse = {0};
    mouse.button = 1;
    mouse.type = GDK_2BUTTON_PRESS;
    press(pin->canvas, &mouse, pin);
    apply(pin, 0);
    visibility_action();
    mc_linux_pins_close_interactive();
    ok = delete_request(pin->window, NULL, pin) && ok;
    ok = pins && pin->passthrough && pin->selected && !pin->hidden && pin->scale == old &&
         pin->opacity == opacity && ok;
    ok = smoke_recover_key(pin) && ok;
  }
  pin->selected = TRUE;
  event.state = 0;
  event.keyval = GDK_KEY_Escape;
  key(pin->window, &event, pin);
  ok = pins == NULL && ok;
  image = gdk_pixbuf_new(GDK_COLORSPACE_RGB, FALSE, 8, 120, 80);
  gdk_pixbuf_fill(image, 0xAA7744FF);
  mc_linux_pin_image(image);
  g_object_unref(image);
  pin = pins->data;
  GdkEventButton twice = {0};
  twice.button = 1;
  twice.type = GDK_2BUTTON_PRESS;
  press(pin->canvas, &twice, pin);
  ok = pins == NULL && ok;
  /* Disabling is real teardown, not just a hidden menu. Preserve bindings,
   * revoke stale entry points, and permit exactly one later registration. */
  preferences = mc_linux_pin_preferences();
  g_object_ref_sink(preferences);
  begin(NULL, GINT_TO_POINTER(0));
  saved = record_key(NULL, &config_event, NULL) && saved;
  Binding retained = bindings[0];
  image = gdk_pixbuf_new(GDK_COLORSPACE_RGB, FALSE, 8, 120, 80);
  mc_linux_pin_image(image);
  pin = pins ? pins->data : NULL;
  ok = pin != NULL && ok;
  if (pin && x11_available()) ok = set_passthrough(pin, TRUE) && ok;
  begin(NULL, GINT_TO_POINTER(1));
  mc_linux_pins_set_enabled(FALSE);
  ok = !mc_linux_pins_enabled() && !pins && !filter_added && !global_ready[0] && !global_ready[1] &&
       !global_down[0] && !global_down[1] && recording == -1 && !gtk_widget_get_sensitive(preferences) && ok;
  begin(NULL, GINT_TO_POINTER(1));
  reset_keys(NULL, NULL);
  mc_linux_pin_image(image);
  ok = recording == -1 && !record_key(NULL, &config_event, NULL) && !pins && same(retained, bindings[0]) && ok;
  mc_linux_pins_set_enabled(FALSE);
  mc_linux_pins_set_enabled(TRUE);
  mc_linux_pins_set_enabled(TRUE);
  ok = mc_linux_pins_enabled() && gtk_widget_get_sensitive(preferences) && same(retained, bindings[0]) && ok;
  mc_linux_pin_image(image);
  pin = pins ? pins->data : NULL;
  ok = pin != NULL && ok;
  if (pin && x11_available())
    ok = global_ready[0] && global_ready[1] && filter_added && set_passthrough(pin, TRUE) && smoke_recover_key(pin) && ok;
  g_object_unref(image);
  reset_keys(NULL, NULL);
  gtk_widget_destroy(preferences);
  g_object_unref(preferences);
  mc_linux_pins_close();
  g_print("Linux pin lifecycle smoke %s: release grabs/filter, terminate pass-through, reject disabled calls, retain bindings, re-enable recovery.\n", ok && saved ? "passed" : "FAILED");
  return ok && saved && interaction_ok;
}
