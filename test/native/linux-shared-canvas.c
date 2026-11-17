/* Real GTK/ATK + shared MoonBit v2 fixture. Synthetic presentation/clock only:
 * this verifies a reusable canvas, not a Linux video playback backend. */
#include <gtk/gtk.h>
#include <atk/atk.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "platform/linux/graphics/shared_canvas.h"
#include "bindings/c/video_ui.h"
#include "bindings/c/video_project.h"

typedef struct {
  GtkWidget *canvas;
  int32_t project, ui, frame;
  char *snapshot, *frame_json;
  double width, height;
  unsigned commands, inputs, cancels, plays;
  MCCanvasInput last_input;
  gboolean failed, destroyed, destroy_on_input;
} Harness;
static moonbit_string_t input(const char *text) {
  glong length = 0; gunichar2 *utf16 = g_utf8_to_utf16(text, -1, NULL, &length, NULL);
  moonbit_string_t result = moonbit_make_string_raw((int32_t)length);
  if (length) memcpy(result, utf16, (size_t)length * sizeof(uint16_t));
  g_free(utf16); return result;
}
static char *output(moonbit_string_t text) {
  char *result = g_utf16_to_utf8(text, Moonbit_array_length(text), NULL, NULL, NULL); moonbit_decref(text); return result;
}
/* Trusted fixture-output extraction only; production adapters do not parse
 * document/effect JSON or reproduce timeline operations. */
static const char *field(const char *json, const char *key) {
  char pattern[80]; g_snprintf(pattern, sizeof(pattern), "\"%s\":", key);
  const char *at = json ? strstr(json, pattern) : NULL;
  if (!at) return NULL;
  at += strlen(pattern);
  while (*at == ' ' || *at == '\n') at++;
  return at;
}
static gboolean flag(const char *json, const char *key) { const char *at = field(json, key); return at && !strncmp(at, "true", 4); }
static double number(const char *json, const char *key) { const char *at = field(json, key); return at ? g_ascii_strtod(at, NULL) : -1; }
static char *object(const char *json, const char *key) {
  const char *start = field(json, key); if (!start || *start != '{') return NULL;
  int depth = 0; gboolean quoted = FALSE, escaped = FALSE;
  for (const char *at = start; *at; at++) {
    if (quoted) { if (escaped) escaped = FALSE; else if (*at == '\\') escaped = TRUE; else if (*at == '"') quoted = FALSE; }
    else if (*at == '"') quoted = TRUE;
    else if (*at == '{') depth++;
    else if (*at == '}' && !--depth) return g_strndup(start, (gsize)(at - start + 1));
  }
  return NULL;
}
static void render(Harness *h) {
  if (!h->canvas || h->destroyed || h->width <= 0 || h->height <= 0) return;
  moonbit_string_t json = video_ui_frame(h->ui, h->width, h->height);
  int32_t frame = ui_frame_open(json); g_free(h->frame_json); h->frame_json = output(json);
  if (!frame || !mc_linux_canvas_set_frame(h->canvas, frame)) {
    if (frame) ui_frame_close(frame);
    h->failed = TRUE;
    return;
  }
  h->frame = frame;
}
static void send_json(Harness *h, const char *json) {
  moonbit_string_t encoded = input(json); char *result = output(video_ui_event(h->ui, encoded)); moonbit_decref(encoded);
  if (!result || !flag(result, "ok")) { h->failed = TRUE; g_free(result); return; }
  if (h->canvas) mc_linux_canvas_set_capture(h->canvas, flag(result, "capture"));
  char *command = object(result, "command");
  if (command) {
    char *request = g_strdup_printf("{\"expectedRevision\":%.0f,\"requestId\":\"gtk-canvas-%u\",%s",
        number(h->snapshot, "revision"), ++h->commands, command + 1);
    encoded = input(request); char *next = output(video_project_command(h->project, encoded)); moonbit_decref(encoded);
    if (!next || !flag(next, "ok")) { h->failed = TRUE; g_free(next); }
    else { g_free(h->snapshot); h->snapshot = next;
      char *event = g_strdup_printf("{\"type\":\"snapshot\",\"snapshot\":%s}", next); send_json(h, event); g_free(event); }
    g_free(request); g_free(command);
  }
  if (strstr(result, "\"type\":\"play\"")) h->plays++;
  g_free(result); render(h);
}
static void on_input(void *context, GtkWidget *widget, const MCCanvasInput *event) {
  Harness *h = context; h->inputs++; h->last_input = *event; h->last_input.text = NULL;
  if (event->type == MC_UI_INPUT_CANCEL) h->cancels++;
  if (h->destroy_on_input && event->type == MC_UI_INPUT_POINTER_DOWN) { gtk_widget_destroy(widget); return; }
  char *text = output(mc_canvas_input_json(event));
  if (!text || !*text) h->failed = TRUE;
  else send_json(h, text);
  g_free(text);
}
static void on_resize(void *context, GtkWidget *widget, double width, double height) {
  Harness *h = context; h->canvas = widget; h->width = width; h->height = height; render(h);
}
static void on_destroyed(void *context, GtkWidget *widget) { (void)widget; Harness *h = context; h->destroyed = TRUE; h->canvas = NULL; }
static void video_fixture(void *context, GtkWidget *widget, cairo_t *cr, const MCCanvasRect *rect) {
  (void)context; (void)widget; cairo_set_source_rgb(cr, 0, 1, 0); cairo_rectangle(cr, rect->x, rect->y, rect->width, rect->height); cairo_fill(cr);
}
static void drain(void) {
  gint64 until = g_get_monotonic_time() + 50000;
  do { while (g_main_context_iteration(NULL, FALSE)) {} g_usleep(1000); }
  while (g_get_monotonic_time() < until);
}
static GdkDevice *pointer_device(GtkWidget *widget) {
  return gdk_seat_get_pointer(gdk_display_get_default_seat(gtk_widget_get_display(widget)));
}
static void pointer_event(Harness *h, GdkEventType type, double x, double y) {
  if (!h->canvas || !gtk_widget_get_window(h->canvas)) { h->failed = TRUE; return; }
  GdkEvent *event = gdk_event_new(type); event->any.window = g_object_ref(gtk_widget_get_window(h->canvas)); event->any.send_event = TRUE;
  if (type == GDK_MOTION_NOTIFY) { event->motion.time = GDK_CURRENT_TIME; event->motion.x = x; event->motion.y = y; event->motion.state = GDK_BUTTON1_MASK; }
  else { event->button.time = GDK_CURRENT_TIME; event->button.x = x; event->button.y = y; event->button.button = 1;
    event->button.state = type == GDK_BUTTON_PRESS ? 0 : GDK_BUTTON1_MASK; }
  gdk_event_set_device(event, pointer_device(h->canvas)); gtk_widget_event(h->canvas, event); gdk_event_free(event);
}
static int semantic(Harness *h, const char *id) {
  for (int i = 0; i < ui_frame_semantic_count(h->frame); i++) {
    char *text = output(ui_frame_semantic_text(h->frame, i, MC_UI_SEM_ID)); gboolean found = text && !strcmp(text, id);
    g_free(text); if (found) return i;
  }
  return -1;
}
static void semantic_point(Harness *h, int index, double *x, double *y) {
  *x = ui_frame_semantic_number(h->frame, index, MC_UI_SEM_X) + ui_frame_semantic_number(h->frame, index, MC_UI_SEM_WIDTH) / 2;
  *y = ui_frame_semantic_number(h->frame, index, MC_UI_SEM_Y) + ui_frame_semantic_number(h->frame, index, MC_UI_SEM_HEIGHT) / 2;
}
static void click(Harness *h, const char *id) {
  int i = semantic(h, id); if (i < 0) { h->failed = TRUE; return; }
  double x, y; semantic_point(h, i, &x, &y); pointer_event(h, GDK_BUTTON_PRESS, x, y); pointer_event(h, GDK_BUTTON_RELEASE, x, y);
}
static void key(Harness *h, guint keyval, GdkModifierType modifiers) {
  gtk_widget_grab_focus(h->canvas);
  GdkEvent *event = gdk_event_new(GDK_KEY_PRESS); event->key.window = g_object_ref(gtk_widget_get_window(h->canvas));
  event->key.send_event = TRUE; event->key.time = GDK_CURRENT_TIME; event->key.keyval = keyval; event->key.state = modifiers;
  gdk_event_set_device(event, gdk_seat_get_keyboard(gdk_display_get_default_seat(gtk_widget_get_display(h->canvas))));
  gtk_widget_event(h->canvas, event); gdk_event_free(event);
}
static guint32 pixel(cairo_surface_t *surface, int x, int y) {
  const unsigned char *data = cairo_image_surface_get_data(surface);
  const guint32 *row = (const guint32 *)(data + y * cairo_image_surface_get_stride(surface)); return row[x] & 0xffffff;
}
static gboolean screenshot(GtkWidget *widget, const char *path, double scale, gboolean fixture, guint32 *corner) {
  int width = fixture ? 200 : gtk_widget_get_allocated_width(widget);
  int height = fixture ? 120 : gtk_widget_get_allocated_height(widget);
  cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, (int)ceil(width * scale), (int)ceil(height * scale));
  cairo_t *cr = cairo_create(surface); cairo_scale(cr, scale, scale);
  gboolean ok = mc_linux_canvas_paint(widget, cr, width, height); cairo_surface_flush(surface);
  if (corner) *corner = pixel(surface, 2, 2);
  if (fixture) {
    ok = ok && pixel(surface, (int)(20 * scale), (int)(20 * scale)) == 0xff0000 &&
        pixel(surface, (int)(15 * scale), (int)(65 * scale)) == 0x00ff00 &&
        pixel(surface, (int)(25 * scale), (int)(75 * scale)) == 0xffffff &&
        pixel(surface, (int)(4 * scale), (int)(4 * scale)) == 0x101010 &&
        pixel(surface, (int)(20 * scale), (int)(40 * scale)) == 0x0000ff;
    unsigned glyphs = 0;
    for (int y = (int)(10 * scale); y < (int)(40 * scale); y++)
      for (int x = (int)(60 * scale); x < (int)(180 * scale); x++) if (pixel(surface, x, y) != 0x101010) glyphs++;
    ok = ok && glyphs > 15 && pixel(surface, (int)(185 * scale), (int)(20 * scale)) == 0x101010;
  }
  ok = cairo_status(cr) == CAIRO_STATUS_SUCCESS && cairo_surface_write_to_png(surface, path) == CAIRO_STATUS_SUCCESS && ok;
  cairo_destroy(cr); cairo_surface_destroy(surface); return ok;
}
static gboolean install_json(Harness *h, const char *json) {
  moonbit_string_t text = input(json); int32_t frame = ui_frame_open(text); moonbit_decref(text);
  if (!frame) return FALSE;
  if (!mc_linux_canvas_set_frame(h->canvas, frame)) { ui_frame_close(frame); return FALSE; }
  h->frame = frame; return TRUE;
}
static AtkObject *find_accessible(AtkObject *root, const char *label) {
  if (!label) return NULL;
  for (int i = 0; i < atk_object_get_n_accessible_children(root); i++) {
    AtkObject *child = atk_object_ref_accessible_child(root, i);
    if (child && !g_strcmp0(atk_object_get_name(child), label)) return child;
    if (child) g_object_unref(child);
  }
  return NULL;
}
static AtkObject *accessible_semantic(Harness *h, AtkObject *root, const char *id) {
  int index = semantic(h, id);
  if (index < 0) return NULL;
  char *label = output(ui_frame_semantic_text(h->frame, index, MC_UI_SEM_LABEL));
  AtkObject *child = find_accessible(root, label); g_free(label); return child;
}
static gboolean has_gap(Harness *h) {
  for (int i = 0; i < ui_frame_semantic_count(h->frame); i++) {
    char *id = output(ui_frame_semantic_text(h->frame, i, MC_UI_SEM_ID));
    gboolean gap = id && g_str_has_prefix(id, "gap:"); g_free(id);
    if (gap) return TRUE;
  }
  return FALSE;
}
typedef struct { Harness *h; gboolean fired, disabled; } FocusReplacement;
static gboolean replace_on_focus(GtkWidget *widget, GdkEventFocus *event, gpointer data) {
  (void)widget; (void)event;
  FocusReplacement *swap = data;
  swap->fired = TRUE;
  const char *json = swap->disabled
      ? "{\"ok\":true,\"commands\":[],\"semantics\":[{\"id\":\"play\",\"role\":\"button\",\"label\":\"Disabled play\","
        "\"x\":0,\"y\":0,\"width\":30,\"height\":30,\"enabled\":false,\"focused\":false}]}"
      : "{\"ok\":true,\"commands\":[],\"semantics\":[]}";
  if (!install_json(swap->h, json)) swap->h->failed = TRUE;
  return FALSE;
}
/* Real Gtk focus-in delivery must synchronously replace the semantic tree
 * inside do_action's grab_focus call; a missing event is a failure, not a skip. */
static gboolean focus_reentrancy(Harness *h, GtkWidget *other, AtkObject *root, gboolean disabled) {
  render(h);
  AtkObject *node = accessible_semantic(h, root, "play");
  if (!node || !ATK_IS_ACTION(node)) {
    if (node) g_object_unref(node);
    return FALSE;
  }
  gtk_widget_grab_focus(other); drain();
  if (!gtk_widget_has_focus(other)) { g_object_unref(node); return FALSE; }
  FocusReplacement swap = {h, FALSE, disabled};
  gulong handler = g_signal_connect(h->canvas, "focus-in-event", G_CALLBACK(replace_on_focus), &swap);
  unsigned inputs = h->inputs;
  gboolean activated = atk_action_do_action(ATK_ACTION(node), 0);
  gboolean ok = swap.fired && gtk_widget_has_focus(h->canvas) && !activated && h->inputs == inputs;
  g_signal_handler_disconnect(h->canvas, handler);
  g_object_unref(node); render(h);
  return ok;
}
typedef struct { GtkWidget *widget; unsigned calls; } ChildrenDestroy;
static void destroy_on_child(AtkObject *object, guint index, gpointer child, gpointer data) {
  (void)object; (void)index; (void)child;
  ChildrenDestroy *state = data;
  state->calls++;
  gtk_widget_destroy(state->widget);
}
static gboolean children_reentrant_destroy(void) {
  MCLinuxCanvasCallbacks callbacks = {0};
  GtkWidget *widget = g_object_ref_sink(mc_linux_canvas_new(&callbacks, NULL));
  AtkObject *root = g_object_ref(gtk_widget_get_accessible(widget));
  ChildrenDestroy state = {widget, 0};
  g_signal_connect(root, "children-changed::add", G_CALLBACK(destroy_on_child), &state);
  moonbit_string_t text = input("{\"ok\":true,\"commands\":[],\"semantics\":["
      "{\"id\":\"first\",\"role\":\"button\",\"label\":\"First\",\"enabled\":true,\"x\":0,\"y\":0,\"width\":10,\"height\":10},"
      "{\"id\":\"second\",\"role\":\"button\",\"label\":\"Second\",\"enabled\":true,\"x\":20,\"y\":0,\"width\":10,\"height\":10}]}");
  int32_t frame = ui_frame_open(text); moonbit_decref(text);
  gboolean consumed = frame > 0 && mc_linux_canvas_set_frame(widget, frame);
  gboolean ok = consumed && state.calls == 1 && ui_frame_command_count(frame, MC_UI_LAYER_COMMANDS) == -1 &&
      atk_object_get_n_accessible_children(root) == 0;
  if (!consumed && frame > 0) ui_frame_close(frame);
  gtk_widget_destroy(widget); g_object_unref(root); g_object_unref(widget);
  return ok;
}
#define CHECK(test, label) do { if (!(test)) { fprintf(stderr, "FAIL GTK canvas: %s\n", label); passed = FALSE; } } while (0)
int main(int argc, char **argv) {
  if (argc != 2) return 2;
  char *directory = g_strdup(argv[1]);
  if (!gtk_init_check(NULL, NULL) || g_mkdir_with_parents(directory, 0700) != 0) { g_free(directory); return 2; }
  moonbit_init();
  gboolean passed = TRUE; Harness h = {0}; h.project = h.ui = -1;
  AtkObject *accessible = NULL, *play = NULL;
  GtkWidget *window = gtk_window_new(GTK_WINDOW_TOPLEVEL); gtk_window_set_default_size(GTK_WINDOW(window), 1040, 760);
  gtk_window_set_title(GTK_WINDOW(window), "Shared canvas fixture");
  GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0), *other_focus = gtk_entry_new();
  gtk_container_add(GTK_CONTAINER(window), box);
  moonbit_string_t source = input("{\"durationMs\":4000,\"width\":320,\"height\":240,\"hasAudio\":true}"), draft = input("");
  h.snapshot = output(video_project_open(source, draft)); moonbit_decref(source); moonbit_decref(draft);
  CHECK(h.snapshot && flag(h.snapshot, "ok"), "real v2 project opens"); if (!passed) goto cleanup;
  h.project = (int32_t)number(h.snapshot, "session"); source = input(h.snapshot); h.ui = video_ui_open(source); moonbit_decref(source);
  CHECK(h.ui >= 0, "shared UI opens from authoritative snapshot"); if (!passed) goto cleanup;
  MCLinuxCanvasCallbacks callbacks = {on_input, on_resize, on_destroyed, video_fixture};
  h.canvas = mc_linux_canvas_new(&callbacks, &h); CHECK(h.canvas, "GTK native canvas created"); if (!passed) goto cleanup;
  gtk_box_pack_start(GTK_BOX(box), h.canvas, TRUE, TRUE, 0);
  gtk_box_pack_end(GTK_BOX(box), other_focus, FALSE, FALSE, 0);
  gtk_widget_show_all(window); gtk_window_present(GTK_WINDOW(window));
  gtk_widget_grab_focus(h.canvas); drain();
  CHECK(h.frame > 0 && !h.failed, "GTK size allocation produces an owned typed frame");
  if (!passed) goto cleanup;
  click(&h, "clip:v1");
  int split = semantic(&h, "project-split"), playhead = semantic(&h, "playhead");
  CHECK(split >= 0 && playhead >= 0 && h.commands == 0 &&
      ui_frame_semantic_number(h.frame, playhead, MC_UI_SEM_VALUE) == 0 &&
      ui_frame_semantic_value(h.frame, split, MC_UI_SEM_ENABLED) == 0,
      "selecting a clip preserves the playhead and cannot split at its boundary");
  /* Clip-body input selects or moves clips; seeking is an independent ruler
   * gesture. Exercise both real native paths before invoking split. */
  click(&h, "playhead");
  split = semantic(&h, "project-split"); playhead = semantic(&h, "playhead");
  CHECK(split >= 0 && playhead >= 0 && h.commands == 0 &&
      ui_frame_semantic_number(h.frame, playhead, MC_UI_SEM_VALUE) > 0 &&
      ui_frame_semantic_number(h.frame, playhead, MC_UI_SEM_VALUE) < 4000 &&
      ui_frame_semantic_value(h.frame, split, MC_UI_SEM_ENABLED) == 1,
      "native ruler click seeks inside the selected clip and enables split");
  click(&h, "project-split");
  CHECK(h.commands == 1 && !h.failed, "real GTK pointer events split through shared UI and core");
  int second = -1;
  for (int i = 0; i < ui_frame_semantic_count(h.frame); i++) {
    char *id = output(ui_frame_semantic_text(h.frame, i, MC_UI_SEM_ID));
    if (id && !strncmp(id, "clip:v", 6) && strcmp(id, "clip:v1")) second = i;
    g_free(id);
  }
  CHECK(second >= 0, "split produces another actual video clip");
  if (second >= 0) {
    double x, y; semantic_point(&h, second, &x, &y); unsigned commands = h.commands;
    pointer_event(&h, GDK_BUTTON_PRESS, x, y); pointer_event(&h, GDK_MOTION_NOTIFY, x + 160, y);
    CHECK(gtk_widget_has_grab(h.canvas), "shared capture request acquires the GTK grab");
    key(&h, GDK_KEY_Escape, 0); pointer_event(&h, GDK_BUTTON_RELEASE, x + 160, y);
    CHECK(h.commands == commands && !has_gap(&h) && !gtk_widget_has_grab(h.canvas), "Escape cancels placement and late release cannot commit");
    unsigned cancelled = h.cancels;
    pointer_event(&h, GDK_BUTTON_PRESS, x, y); pointer_event(&h, GDK_MOTION_NOTIFY, x + 160, y);
    GdkEvent *broken = gdk_event_new(GDK_GRAB_BROKEN);
    broken->grab_broken.window = g_object_ref(gtk_widget_get_window(h.canvas));
    broken->grab_broken.send_event = TRUE; broken->grab_broken.implicit = TRUE;
    gtk_widget_event(h.canvas, broken); gdk_event_free(broken);
    pointer_event(&h, GDK_BUTTON_RELEASE, x + 160, y);
    CHECK(h.cancels > cancelled && h.commands == commands && !gtk_widget_has_grab(h.canvas),
        "native grab loss cancels shared placement before a late release");
    cancelled = h.cancels;
    pointer_event(&h, GDK_BUTTON_PRESS, x, y); pointer_event(&h, GDK_MOTION_NOTIFY, x + 160, y);
    gtk_grab_add(other_focus); gtk_grab_remove(other_focus);
    pointer_event(&h, GDK_BUTTON_RELEASE, x + 160, y);
    CHECK(h.cancels > cancelled && h.commands == commands && !gtk_widget_has_grab(h.canvas),
        "real sibling GTK grab cancels placement and suppresses late commit");
    pointer_event(&h, GDK_BUTTON_PRESS, x, y); pointer_event(&h, GDK_MOTION_NOTIFY, x + 160, y); pointer_event(&h, GDK_BUTTON_RELEASE, x + 160, y);
    gboolean gap = FALSE;
    for (int i = 0; i < ui_frame_semantic_count(h.frame); i++) {
      char *id = output(ui_frame_semantic_text(h.frame, i, MC_UI_SEM_ID)); gap |= id && !strncmp(id, "gap:", 4); g_free(id);
    }
    CHECK(h.commands == commands + 1 && gap && !h.failed, "body drag leaves an actual gap without GTK timeline rules");
    key(&h, GDK_KEY_z, GDK_CONTROL_MASK); CHECK(h.commands == commands + 2 && !has_gap(&h) && !h.failed, "Ctrl+Z follows the same core undo path and removes the gap");
  }
  double span = number(field(h.frame_json, "viewport"), "spanMs");
  char *zoom_snapshot = g_strdup(h.snapshot), *zoom_plan = object(h.snapshot, "plan");
  double fit_duration_ms = number(zoom_plan, "outputDurationTicks") * 1000.0 / number(zoom_plan, "timebase");
  CHECK(zoom_plan && number(zoom_plan, "timebase") > 0 && fit_duration_ms > 0,
      "fit expectation comes from the authoritative current output plan");
  g_free(zoom_plan);
  unsigned zoom_commands = h.commands;
  GdkEvent *scroll = gdk_event_new(GDK_SCROLL); scroll->scroll.window = g_object_ref(gtk_widget_get_window(h.canvas));
  scroll->scroll.send_event = TRUE; scroll->scroll.time = GDK_CURRENT_TIME; scroll->scroll.x = 400; scroll->scroll.y = h.height - 120;
  scroll->scroll.state = GDK_CONTROL_MASK; scroll->scroll.direction = GDK_SCROLL_UP; gdk_event_set_device(scroll, pointer_device(h.canvas));
  gtk_widget_event(h.canvas, scroll); gdk_event_free(scroll);
  CHECK(h.last_input.type == MC_UI_INPUT_SCROLL && number(field(h.frame_json, "viewport"), "spanMs") < span,
      "native Ctrl+scroll changes shared viewport zoom");
  double discrete_span = number(field(h.frame_json, "viewport"), "spanMs");
  scroll = gdk_event_new(GDK_SCROLL); scroll->scroll.window = g_object_ref(gtk_widget_get_window(h.canvas));
  scroll->scroll.send_event = TRUE; scroll->scroll.x = 400; scroll->scroll.y = h.height - 120;
  scroll->scroll.state = GDK_CONTROL_MASK; scroll->scroll.direction = GDK_SCROLL_SMOOTH; scroll->scroll.delta_y = -.5;
  gdk_event_set_device(scroll, pointer_device(h.canvas)); gtk_widget_event(h.canvas, scroll); gdk_event_free(scroll);
  CHECK(h.last_input.type == MC_UI_INPUT_SCROLL && fabs(h.last_input.delta_y - .5) < .00001 &&
      !(h.last_input.flags & MC_UI_INPUT_PRECISE) && number(field(h.frame_json, "viewport"), "spanMs") < discrete_span,
      "GDK smooth input preserves fractional wheel steps and normalized upward direction");
  double wheel_span = number(field(h.frame_json, "viewport"), "spanMs");
  key(&h, GDK_KEY_plus, GDK_CONTROL_MASK);
  CHECK(number(field(h.frame_json, "viewport"), "spanMs") < wheel_span, "Ctrl+plus reaches shared zoom");
  key(&h, GDK_KEY_0, GDK_CONTROL_MASK);
  /* Undo preserves the wider editing view after a gap extended the output.
   * Explicit fit targets the current plan, not that retained historical span.
   * Zoom is keyboard/wheel-only; there is no visible fit-button semantic. */
  double fit_span_ms = number(field(h.frame_json, "viewport"), "spanMs");
  double fit_start_ms = number(field(h.frame_json, "viewport"), "startMs");
  gboolean fit_matches = fabs(fit_span_ms - fit_duration_ms) < .0001 && fabs(fit_start_ms) < .0001;
  gboolean zoom_unchanged = h.commands == zoom_commands &&
    number(h.frame_json, "revision") == number(zoom_snapshot, "revision") && !g_strcmp0(h.snapshot, zoom_snapshot);
  if (!fit_matches || !zoom_unchanged)
    fprintf(stderr, "GTK fit state: start=%.9f span=%.9f expected=%.9f commands=%u/%u revision=%.0f/%.0f snapshot_equal=%d\n",
      fit_start_ms, fit_span_ms, fit_duration_ms, h.commands, zoom_commands,
      number(h.frame_json, "revision"), number(zoom_snapshot, "revision"), !g_strcmp0(h.snapshot, zoom_snapshot));
  CHECK(fit_matches, "Ctrl+0 fits the authoritative current output from zero");
  CHECK(zoom_unchanged, "wheel and keyboard zoom preserve commands, revision and the complete snapshot");
  g_free(zoom_snapshot);
  unsigned cancelled = h.cancels;
  GdkEvent *focus = gdk_event_new(GDK_FOCUS_CHANGE); focus->focus_change.window = g_object_ref(gtk_widget_get_window(h.canvas));
  focus->focus_change.send_event = TRUE; focus->focus_change.in = FALSE; gtk_widget_event(h.canvas, focus); gdk_event_free(focus);
  CHECK(h.cancels > cancelled, "native focus loss cancels shared input"); gtk_widget_grab_focus(h.canvas);
  guint32 light = 0, dark = 0;
  send_json(&h, "{\"type\":\"appearance\",\"mode\":\"light\"}");
  char *path = g_build_filename(directory, "video-ui-light.png", NULL);
  CHECK(screenshot(h.canvas, path, 1, FALSE, &light), "actual light v2 scene renders to PNG"); g_free(path);
  send_json(&h, "{\"type\":\"appearance\",\"mode\":\"dark\"}");
  path = g_build_filename(directory, "video-ui-dark.png", NULL);
  CHECK(screenshot(h.canvas, path, 1, FALSE, &dark), "actual dark v2 scene renders to PNG"); g_free(path);
  CHECK((light & 255) > 200 && (dark & 255) < 60 && light != dark, "real pixels follow shared light/dark appearance");
  accessible = g_object_ref(gtk_widget_get_accessible(h.canvas));
  CHECK(atk_object_get_n_accessible_children(accessible) == ui_frame_semantic_count(h.frame), "ATK exposes all shared semantic nodes");
  CHECK(focus_reentrancy(&h, other_focus, accessible, FALSE), "synchronous focus-in frame removal blocks stale ATK activation");
  CHECK(focus_reentrancy(&h, other_focus, accessible, TRUE), "synchronous focus-in disabling blocks stale ATK activation");
  play = accessible_semantic(&h, accessible, "play");
  CHECK(play && atk_object_get_role(play) == ATK_ROLE_PUSH_BUTTON && ATK_IS_ACTION(play), "ATK exposes shared label, role and action");
  if (play && ATK_IS_ACTION(play)) { unsigned plays = h.plays;
    CHECK(atk_action_do_action(ATK_ACTION(play), 0) && h.plays == plays + 1, "ATK activate routes through shared UI effects"); }
  AtkObject *slider = accessible_semantic(&h, accessible, "playhead");
  CHECK(slider && ATK_IS_VALUE(slider) && atk_object_get_role(slider) == ATK_ROLE_SLIDER, "shared playhead exposes AtkValue");
  if (slider && ATK_IS_VALUE(slider)) {
    double value = -1; char *text = NULL;
    atk_value_get_value_and_text(ATK_VALUE(slider), &value, &text); g_free(text);
    int index = semantic(&h, "playhead"); AtkRange *range = atk_value_get_range(ATK_VALUE(slider));
    CHECK(index >= 0 && fabs(value - ui_frame_semantic_number(h.frame, index, MC_UI_SEM_VALUE)) < .0001 &&
        range && fabs(atk_range_get_lower_limit(range) - ui_frame_semantic_number(h.frame, index, MC_UI_SEM_MIN)) < .0001 &&
        fabs(atk_range_get_upper_limit(range) - ui_frame_semantic_number(h.frame, index, MC_UI_SEM_MAX)) < .0001,
        "ATK value/range match shared playhead state");
    if (range) atk_range_free(range);
  }
  if (slider) g_object_unref(slider);
  CHECK(install_json(&h, "{\"ok\":true,\"commands\":[],\"semantics\":["
      "{\"id\":\"play\",\"role\":\"button\",\"label\":\"Play\",\"enabled\":true,\"x\":0,\"y\":0,\"width\":30,\"height\":30},"
      "{\"id\":\"playhead\",\"role\":\"slider\",\"label\":\"Position\",\"value\":2000,\"min\":0,\"max\":4000,"
      "\"enabled\":true,\"x\":40,\"y\":0,\"width\":80,\"height\":30}]}"), "install semantic reorder baseline");
  CHECK(install_json(&h, "{\"ok\":true,\"commands\":[],\"semantics\":["
      "{\"id\":\"playhead\",\"role\":\"slider\",\"label\":\"Position\",\"value\":2000,\"min\":0,\"max\":4000,"
      "\"enabled\":true,\"x\":40,\"y\":0,\"width\":80,\"height\":30},"
      "{\"id\":\"play\",\"role\":\"button\",\"label\":\"Play\",\"enabled\":true,\"x\":0,\"y\":0,\"width\":30,\"height\":30}]}"),
      "reorder same semantic IDs without removing them");
  AtkObject *reordered = find_accessible(accessible, "Play");
  CHECK(play && reordered == play && atk_object_get_index_in_parent(reordered) == 1,
      "semantic reorder preserves ATK identity and updates its index");
  if (reordered) g_object_unref(reordered);
  render(&h);
  int32_t replaced = h.frame;
  CHECK(install_json(&h, "{\"ok\":true,\"commands\":["
      "{\"type\":\"rect\",\"x\":0,\"y\":0,\"width\":200,\"height\":120,\"fill\":\"#101010\"},"
      "{\"type\":\"rect\",\"x\":10,\"y\":10,\"width\":30,\"height\":20,\"fill\":\"#ff0000\"},"
      "{\"type\":\"line\",\"x1\":10,\"y1\":40,\"x2\":50,\"y2\":40,\"color\":\"#0000ff\",\"lineWidth\":2},"
      "{\"type\":\"text\",\"x\":60,\"y\":10,\"width\":120,\"height\":30,\"text\":\"中 A&B\",\"size\":16,\"color\":\"#ffffff\",\"align\":\"center\",\"valign\":\"center\"}],"
      "\"videoRect\":{\"x\":10,\"y\":60,\"width\":60,\"height\":40},\"overlayCommands\":["
      "{\"type\":\"rect\",\"x\":20,\"y\":70,\"width\":10,\"height\":10,\"fill\":\"#ffffff\"}],"
      "\"semantics\":[{\"id\":\"replacement\",\"role\":\"button\",\"label\":\"Replacement\","
      "\"x\":10,\"y\":10,\"width\":30,\"height\":20,\"enabled\":true,\"focused\":false}],\"cursor\":\"default\"}"),
      "primitive fixture uses the same validated immutable frame ABI");
  CHECK(ui_frame_command_count(replaced, MC_UI_LAYER_COMMANDS) == -1, "successful replacement consumes old frame ownership");
  if (play && ATK_IS_ACTION(play)) {
    unsigned inputs = h.inputs;
    CHECK(!atk_action_do_action(ATK_ACTION(play), 0) && h.inputs == inputs, "retired ATK child cannot activate the replacement in its slot");
  }
  CHECK(atk_object_get_n_accessible_children(accessible) == 1, "ATK tree reflects replacement semantics");
  path = g_build_filename(directory, "primitives-1x.png", NULL); CHECK(screenshot(h.canvas, path, 1, TRUE, NULL), "Cairo pixels validate fill/line, Unicode clipping and media/overlay order"); g_free(path);
  path = g_build_filename(directory, "primitives-1.5x.png", NULL); CHECK(screenshot(h.canvas, path, 1.5, TRUE, NULL), "one logical coordinate system survives scaled Cairo rendering"); g_free(path);
  CHECK(!mc_linux_canvas_set_frame(h.canvas, INT32_MAX) && ui_frame_command_count(h.frame, MC_UI_LAYER_COMMANDS) > 0, "invalid replacement preserves the current frame");
  render(&h);
  if (play && ATK_IS_ACTION(play)) {
    AtkObject *returned = accessible_semantic(&h, accessible, "play");
    CHECK(returned && returned != play && !atk_action_do_action(ATK_ACTION(play), 0), "old ATK child stays retired when the same semantic ID returns");
    if (returned) g_object_unref(returned);
  }
  CHECK(atk_object_get_n_accessible_children(accessible) == ui_frame_semantic_count(h.frame), "restored frame exposes all live semantic nodes");
  int32_t final_frame = h.frame; h.destroy_on_input = TRUE; pointer_event(&h, GDK_BUTTON_PRESS, 10, 10);
  CHECK(h.destroyed && !h.canvas && ui_frame_command_count(final_frame, MC_UI_LAYER_COMMANDS) == -1 &&
      ui_frame_command_count(h.frame, MC_UI_LAYER_COMMANDS) == -1,
      "synchronous callback destruction closes both prior and cancel-reentrant frame ownership");
  if (play && ATK_IS_ACTION(play)) {
    AtkStateSet *states = atk_object_ref_state_set(play);
    CHECK(!atk_action_do_action(ATK_ACTION(play), 0) && atk_state_set_contains_state(states, ATK_STATE_DEFUNCT), "retained child is defunct after widget destruction");
    g_object_unref(states);
  }
  CHECK(children_reentrant_destroy(), "ATK child notification destruction stops stale adds and releases consumed frame");
cleanup:
  gtk_widget_destroy(window); drain();
  if (play) g_object_unref(play);
  if (accessible) g_object_unref(accessible);
  if (h.ui >= 0) video_ui_close(h.ui);
  if (h.project >= 0) video_project_close(h.project);
  g_free(h.snapshot); g_free(h.frame_json); g_free(directory);
  printf("Linux shared canvas %s: real v2 inputs/core, cancel/undo/zoom, Cairo layers/text, ATK lifetime. No media backend claimed.\n", passed && !h.failed ? "passed" : "FAILED");
  return passed && !h.failed ? 0 : 1;
}
