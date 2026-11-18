#include "text_input.h"
#include <math.h>
#include <string.h>

typedef struct Field Field;
struct MCLinuxTextInputs {
  GtkWidget *fixed;
  GList *fields;
  MCLinuxTextCallbacks callbacks;
  gpointer context;
  int refs;
  gboolean dead;
};
struct Field {
  MCLinuxTextInputs *owner;
  GtkWidget *view;
  GtkTextBuffer *buffer;
  GtkCssProvider *css;
  char *id, *raw, *commit, *css_text;
  int refs, token, version, anchor, focus, marked, action_depth, mutation, suppress, emitting;
  gboolean dead, seen, known, multiline, composing, focused;
  double clip_x, clip_y, clip_width, clip_height;
  guint empty_preedit;
};
static void sync_native(Field *f);
static gboolean flush_field(Field *f);
static void group_unref(MCLinuxTextInputs *g) {
  if (--g->refs) return;
  g_object_unref(g->fixed); g_free(g);
}
static Field *field_ref(Field *f) { f->refs++; return f; }
static void field_unref(gpointer data) {
  Field *f = data;
  if (--f->refs) return;
  g_object_unref(f->view); g_object_unref(f->css);
  g_free(f->id); g_free(f->raw); g_free(f->commit); g_free(f->css_text);
  group_unref(f->owner); g_free(f);
}
static char *owned_text(moonbit_string_t text) {
  char *utf8 = g_utf16_to_utf8((const gunichar2 *)text, Moonbit_array_length(text), NULL, NULL, NULL);
  moonbit_decref(text); return utf8 ? utf8 : g_strdup("");
}
static char *lf_text(const char *text, int length) {
  if (length < 0) length = (int)strlen(text);
  GString *out = g_string_sized_new((gsize)length);
  for (int i = 0; i < length; i++) {
    if (text[i] == '\r') { g_string_append_c(out, '\n'); if (i + 1 < length && text[i + 1] == '\n') i++; }
    else g_string_append_c(out, text[i]);
  }
  return g_string_free(out, FALSE);
}
static int utf16_offset(const char *text, int characters) {
  int result = 0;
  for (const char *p = text; *p && characters-- > 0; p = g_utf8_next_char(p))
    result += g_utf8_get_char(p) > 0xffff ? 2 : 1;
  return result;
}
static int character_offset(const char *text, int units) {
  int result = 0;
  for (const char *p = text; *p && units > 0; p = g_utf8_next_char(p), result++)
    units -= g_utf8_get_char(p) > 0xffff ? 2 : 1;
  return result;
}
static char *native_state(Field *f, int *anchor, int *focus) {
  GtkTextIter begin, end, a, b;
  gtk_text_buffer_get_bounds(f->buffer, &begin, &end);
  char *raw = gtk_text_buffer_get_text(f->buffer, &begin, &end, FALSE);
  gtk_text_buffer_get_iter_at_mark(f->buffer, &a, gtk_text_buffer_get_selection_bound(f->buffer));
  gtk_text_buffer_get_iter_at_mark(f->buffer, &b, gtk_text_buffer_get_insert(f->buffer));
  *anchor = utf16_offset(raw, gtk_text_iter_get_offset(&a));
  *focus = utf16_offset(raw, gtk_text_iter_get_offset(&b));
  return raw;
}
static gboolean emit(Field *f, int type, int start, int end, const char *text, int selection, int anchor, int focus) {
  if (f->dead || f->owner->dead || f->emitting || !f->owner->callbacks.event) return FALSE;
  field_ref(f);
  glong id_length = 0, text_length = 0;
  gunichar2 *id = g_utf8_to_utf16(f->id, -1, NULL, &id_length, NULL);
  gunichar2 *value = g_utf8_to_utf16(text ? text : "", -1, NULL, &text_length, NULL);
  MCCanvasTextInput input = {0};
  input.type = type; input.token = f->token; input.version = f->version;
  input.start = start; input.end = end; input.selection_kind = selection;
  input.anchor = anchor; input.focus = focus;
  input.id = id; input.id_length = (size_t)id_length; input.text = value; input.text_length = (size_t)text_length;
  moonbit_string_t event = mc_canvas_text_input_json(&input);
  int token = f->token, version = f->version;
  f->emitting++;
  gboolean ok = id && value && Moonbit_array_length(event) && f->owner->callbacks.event(f->owner->context, event);
  f->emitting--;
  ok = ok && !f->dead && f->token == token && f->version > version;
  moonbit_decref(event); g_free(id); g_free(value);
  field_unref(f); return ok;
}
static void action(Field *f, int kind) {
  if (f->dead || f->owner->dead || !f->owner->callbacks.action) return;
  field_ref(f); f->owner->callbacks.action(f->owner->context, f->view, kind); field_unref(f);
}
static void sync_native(Field *f) {
  if (f->dead || f->suppress || f->emitting || f->mutation || f->action_depth || f->composing) return;
  int a, b; char *native = native_state(f, &a, &b);
  f->suppress++;
  if (strcmp(native, f->raw)) gtk_text_buffer_set_text(f->buffer, f->raw, -1);
  if (f->known) {
    GtkTextIter anchor, focus;
    gtk_text_buffer_get_iter_at_offset(f->buffer, &anchor, character_offset(f->raw, f->anchor));
    gtk_text_buffer_get_iter_at_offset(f->buffer, &focus, character_offset(f->raw, f->focus));
    gtk_text_buffer_select_range(f->buffer, &focus, &anchor);
  }
  f->suppress--; g_free(native);
}
static gboolean flush_field(Field *f) {
  if (f->dead) return FALSE;
  if (f->suppress || f->emitting || f->mutation || f->action_depth) return TRUE;
  if (f->composing && !f->commit) return TRUE;
  field_ref(f);
  int anchor, focus; char *raw = native_state(f, &anchor, &focus);
  gboolean ok = TRUE;
  if (f->composing) {
    char *commit = g_steal_pointer(&f->commit);
    if (f->empty_preedit) { g_source_remove(f->empty_preedit); f->empty_preedit = 0; }
    /* Keep native synchronization suspended until the shared terminal ACK.
     * A final IME result can exceed a field's limit even when preedit fit.
     * GTK has already ended that composition; on rejection explicitly cancel
     * the shared composition, then restore its initial draft/selection. */
    ok = emit(f, MC_UI_TEXT_COMPOSITION_COMMIT, 0, 0, commit, MC_UI_SELECTION_DIRECTED, anchor, focus);
    if (!f->dead) {
      gboolean terminal = ok && f->marked < 0;
      if (!terminal) terminal = emit(f, MC_UI_TEXT_COMPOSITION_CANCEL, 0, 0, NULL,
          MC_UI_SELECTION_UNKNOWN, 0, 0) && !f->dead && f->marked < 0;
      if (!f->dead && terminal) f->composing = FALSE;
    }
    g_free(commit);
  } else if (strcmp(raw, f->raw)) {
    const char *before = f->raw, *after = raw;
    gsize old = strlen(before), now = strlen(after), first = 0, tail = 0;
    while (first < old && first < now && before[first] == after[first]) first++;
    while (first && first < now && (((unsigned char)after[first] & 0xc0) == 0x80)) first--;
    while (tail < old - first && tail < now - first && before[old - tail - 1] == after[now - tail - 1]) tail++;
    while (tail && (((unsigned char)after[now - tail] & 0xc0) == 0x80)) tail--;
    char *inserted = g_strndup(after + first, now - first - tail);
    int start = utf16_offset(before, (int)g_utf8_pointer_to_offset(before, before + first));
    int end = utf16_offset(before, (int)g_utf8_pointer_to_offset(before, before + old - tail));
    ok = emit(f, MC_UI_TEXT_REPLACE, start, end, inserted, MC_UI_SELECTION_DIRECTED, anchor, focus);
    g_free(inserted);
  } else if (gtk_widget_has_focus(f->view) && (!f->known || f->anchor != anchor || f->focus != focus)) {
    ok = emit(f, MC_UI_TEXT_SELECT, 0, 0, NULL, MC_UI_SELECTION_DIRECTED, anchor, focus);
  }
  if (!f->dead) sync_native(f);
  g_free(raw); field_unref(f); return ok;
}
static void mutation_begin(GtkTextBuffer *buffer, GtkTextIter *where, char *text, int length, gpointer data) {
  Field *f = data;
  if (f->dead || f->suppress) return;
  if (!g_utf8_validate(text, length, NULL)) { g_signal_stop_emission_by_name(buffer, "insert-text"); return; }
  if (memchr(text, '\r', (size_t)length)) {
    char *lf = lf_text(text, length);
    g_signal_stop_emission_by_name(buffer, "insert-text");
    gtk_text_buffer_insert(buffer, where, lf, -1); g_free(lf); return;
  }
  f->mutation++;
  if (f->composing) { g_free(f->commit); f->commit = g_strndup(text, (gsize)length); }
}
static void mutation_end(GtkTextBuffer *buffer, GtkTextIter *where, char *text, int length, gpointer data) {
  (void)text; (void)length;
  Field *f = field_ref(data);
  if (!f->dead && !f->suppress) {
    int offset = gtk_text_iter_get_offset(where);
    if (f->mutation) f->mutation--;
    flush_field(f);
    if (!f->dead) gtk_text_buffer_get_iter_at_offset(buffer, where, MIN(offset, gtk_text_buffer_get_char_count(buffer)));
  }
  field_unref(f);
}
static void delete_begin(GtkTextBuffer *buffer, GtkTextIter *start, GtkTextIter *end, gpointer data) {
  (void)buffer; (void)start; (void)end; Field *f = data;
  if (!f->dead && !f->suppress) f->mutation++;
}
static void delete_end(GtkTextBuffer *buffer, GtkTextIter *start, GtkTextIter *end, gpointer data) {
  Field *f = field_ref(data);
  if (!f->dead && !f->suppress) {
    int offset = gtk_text_iter_get_offset(start);
    if (f->mutation) f->mutation--;
    flush_field(f);
    if (!f->dead) { gtk_text_buffer_get_iter_at_offset(buffer, start, MIN(offset, gtk_text_buffer_get_char_count(buffer))); *end = *start; }
  }
  field_unref(f);
}
static void user_begin(GtkTextBuffer *buffer, gpointer data) {
  (void)buffer; Field *f = data;
  if (!f->dead && !f->suppress) f->action_depth++;
}
static void user_end(GtkTextBuffer *buffer, gpointer data) {
  (void)buffer; Field *f = field_ref(data);
  if (!f->dead && !f->suppress) { if (f->action_depth) f->action_depth--; flush_field(f); }
  field_unref(f);
}
static void mark_set(GtkTextBuffer *buffer, GtkTextIter *where, GtkTextMark *mark, gpointer data) {
  (void)where; Field *f = field_ref(data);
  if (mark == gtk_text_buffer_get_insert(buffer) || mark == gtk_text_buffer_get_selection_bound(buffer)) flush_field(f);
  field_unref(f);
}
static gboolean empty_preedit(gpointer data) {
  Field *f = data; f->empty_preedit = 0;
  if (!f->dead && f->composing && !f->commit) {
    f->composing = FALSE;
    emit(f, MC_UI_TEXT_COMPOSITION_CANCEL, 0, 0, NULL, MC_UI_SELECTION_UNKNOWN, 0, 0);
    if (!f->dead) sync_native(f);
  }
  return G_SOURCE_REMOVE;
}
static void preedit(GtkTextView *view, const char *text, gpointer data) {
  (void)view; Field *f = field_ref(data);
  if (f->dead || f->suppress) { field_unref(f); return; }
  if (!text || !*text) {
    /* GTK emits empty preedit before its buffer commit. Defer cancellation to
     * idle; a following insert/end-user-action must get the terminal ACK first. */
    if (f->composing && !f->empty_preedit)
      f->empty_preedit = g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, empty_preedit, field_ref(f), field_unref);
    field_unref(f); return;
  }
  if (f->empty_preedit) { g_source_remove(f->empty_preedit); f->empty_preedit = 0; }
  int anchor, focus; char *raw = native_state(f, &anchor, &focus); g_free(raw);
  if (!f->composing) {
    flush_field(f);
    if (f->dead) { field_unref(f); return; }
    f->composing = TRUE;
    if (!emit(f, MC_UI_TEXT_COMPOSITION_START, MIN(anchor, focus), MAX(anchor, focus), NULL,
              MC_UI_SELECTION_DIRECTED, anchor, focus)) f->composing = FALSE;
  }
  if (!f->dead && f->composing) {
    char *lf = lf_text(text, -1);
    /* GTK3's preedit-changed has no caret. Preserve that lack of information. */
    emit(f, MC_UI_TEXT_COMPOSITION_UPDATE, 0, 0, lf, MC_UI_SELECTION_UNKNOWN, 0, 0);
    g_free(lf);
  }
  field_unref(f);
}
static gboolean focus_in(GtkWidget *view, GdkEventFocus *event, gpointer data) {
  (void)view; (void)event; Field *f = field_ref(data);
  if (!f->dead && !f->suppress) {
    int a, b; char *raw = native_state(f, &a, &b); g_free(raw);
    emit(f, MC_UI_TEXT_SELECT, 0, 0, NULL,
         f->composing ? MC_UI_SELECTION_UNKNOWN : MC_UI_SELECTION_DIRECTED, f->composing ? 0 : a, f->composing ? 0 : b);
    if (!f->dead) sync_native(f);
  }
  field_unref(f); return FALSE;
}
static gboolean focus_out(GtkWidget *view, GdkEventFocus *event, gpointer data) {
  (void)view; (void)event; Field *f = field_ref(data);
  if (!f->dead && !f->suppress) { flush_field(f); if (!f->dead) action(f, MC_LINUX_TEXT_BLUR); }
  field_unref(f); return FALSE;
}
static gboolean key_press(GtkWidget *view, GdkEventKey *event, gpointer data) {
  (void)view; Field *f = field_ref(data); gboolean handled = FALSE;
  if (!f->dead && !f->suppress && !f->composing) {
    guint key = gdk_keyval_to_lower(event->keyval);
    gboolean control = (event->state & GDK_CONTROL_MASK) != 0;
    if (control && (key == GDK_KEY_z || key == GDK_KEY_y)) {
      flush_field(f);
      if (!f->dead) emit(f, key == GDK_KEY_y || (event->state & GDK_SHIFT_MASK) ? MC_UI_TEXT_REDO : MC_UI_TEXT_UNDO,
                         0, 0, NULL, 0, 0, 0);
      if (!f->dead) sync_native(f);
      handled = TRUE;
    } else if (!f->multiline && (key == GDK_KEY_Up || key == GDK_KEY_Down) && f->owner->callbacks.key) {
      flush_field(f);
      if (!f->dead) {
        const char *name = key == GDK_KEY_Up ? "ArrowUp" : "ArrowDown";
        glong length = 0; gunichar2 *text = g_utf8_to_utf16(name, -1, NULL, &length, NULL);
        MCCanvasInput input = {0}; input.type = MC_UI_INPUT_KEY;
        input.flags = (control ? MC_UI_INPUT_MOD : 0) | ((event->state & GDK_SHIFT_MASK) ? MC_UI_INPUT_SHIFT : 0);
        input.text = text; input.text_length = (size_t)length;
        handled = f->owner->callbacks.key(f->owner->context, &input); g_free(text);
        if (!f->dead) sync_native(f);
      }
    } else if (key == GDK_KEY_Escape || ((key == GDK_KEY_Return || key == GDK_KEY_KP_Enter) && (control || !f->multiline))) {
      flush_field(f);
      if (!f->dead) action(f, key == GDK_KEY_Escape ? MC_LINUX_TEXT_CANCEL : MC_LINUX_TEXT_ACCEPT);
      handled = TRUE;
    }
  }
  field_unref(f); return handled;
}
static void retire(Field *f) {
  if (f->dead) return;
  f->dead = TRUE;
  if (f->empty_preedit) { g_source_remove(f->empty_preedit); f->empty_preedit = 0; }
  g_signal_handlers_disconnect_by_data(f->buffer, f);
  g_signal_handlers_disconnect_by_data(f->view, f);
  gtk_widget_destroy(f->view); field_unref(f);
}
static gboolean field_draw(GtkWidget *widget, cairo_t *cr, gpointer data) {
  (void)widget; Field *f = data;
  cairo_rectangle(cr, f->clip_x, f->clip_y, f->clip_width, f->clip_height);
  cairo_clip(cr); return FALSE;
}
static Field *new_field(MCLinuxTextInputs *g, const char *id) {
  Field *f = g_new0(Field, 1); f->owner = g; g->refs++; f->refs = 1;
  f->id = g_strdup(id); f->raw = g_strdup(""); f->marked = -1;
  f->view = gtk_text_view_new(); g_object_ref_sink(f->view);
  f->buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(f->view));
  gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(f->view), GTK_WRAP_WORD_CHAR);
  gtk_text_view_set_accepts_tab(GTK_TEXT_VIEW(f->view), FALSE);
  gtk_text_view_set_left_margin(GTK_TEXT_VIEW(f->view), 0); gtk_text_view_set_right_margin(GTK_TEXT_VIEW(f->view), 0);
  gtk_text_view_set_top_margin(GTK_TEXT_VIEW(f->view), 0); gtk_text_view_set_bottom_margin(GTK_TEXT_VIEW(f->view), 0);
  f->css = gtk_css_provider_new();
  gtk_style_context_add_provider(gtk_widget_get_style_context(f->view), GTK_STYLE_PROVIDER(f->css), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
  g_signal_connect(f->buffer, "insert-text", G_CALLBACK(mutation_begin), f);
  g_signal_connect_after(f->buffer, "insert-text", G_CALLBACK(mutation_end), f);
  g_signal_connect(f->buffer, "delete-range", G_CALLBACK(delete_begin), f);
  g_signal_connect_after(f->buffer, "delete-range", G_CALLBACK(delete_end), f);
  g_signal_connect(f->buffer, "begin-user-action", G_CALLBACK(user_begin), f);
  g_signal_connect_after(f->buffer, "end-user-action", G_CALLBACK(user_end), f);
  g_signal_connect_after(f->buffer, "mark-set", G_CALLBACK(mark_set), f);
  g_signal_connect(f->view, "draw", G_CALLBACK(field_draw), f);
  g_signal_connect(f->view, "preedit-changed", G_CALLBACK(preedit), f);
  g_signal_connect(f->view, "focus-in-event", G_CALLBACK(focus_in), f);
  g_signal_connect(f->view, "focus-out-event", G_CALLBACK(focus_out), f);
  g_signal_connect(f->view, "key-press-event", G_CALLBACK(key_press), f);
  gtk_fixed_put(GTK_FIXED(g->fixed), f->view, 0, 0);
  g->fields = g_list_append(g->fields, f); return f;
}
MCLinuxTextInputs *mc_linux_text_inputs_new(const MCLinuxTextCallbacks *callbacks, gpointer context) {
  MCLinuxTextInputs *g = g_new0(MCLinuxTextInputs, 1);
  g->refs = 1; if (callbacks) g->callbacks = *callbacks; g->context = context;
  g->fixed = gtk_fixed_new(); g_object_ref_sink(g->fixed); return g;
}
GtkWidget *mc_linux_text_inputs_widget(MCLinuxTextInputs *g) { return g && !g->dead ? g->fixed : NULL; }
void mc_linux_text_inputs_destroy(MCLinuxTextInputs *g) {
  if (!g || g->dead) return;
  g->dead = TRUE;
  while (g->fields) { Field *f = g->fields->data; g->fields = g_list_delete_link(g->fields, g->fields); retire(f); }
  gtk_widget_destroy(g->fixed); group_unref(g);
}
gboolean mc_linux_text_inputs_set_frame(MCLinuxTextInputs *g, int32_t frame) {
  if (!g || g->dead) return FALSE;
  int count = frame ? ui_frame_field_count(frame) : 0;
  if (count < 0) return FALSE;
  g->refs++;
  for (GList *p = g->fields; p; p = p->next) ((Field *)p->data)->seen = FALSE;
  for (int i = 0; i < count && !g->dead; i++) {
    char *id = owned_text(ui_frame_field_text(frame, i, MC_UI_FIELD_ID));
    int token = ui_frame_field_value(frame, i, MC_UI_FIELD_TOKEN), version = ui_frame_field_value(frame, i, MC_UI_FIELD_VERSION);
    Field *f = NULL;
    for (GList *p = g->fields; p; p = p->next) if (!strcmp(((Field *)p->data)->id, id)) { f = p->data; break; }
    if (f && f->token != token) {
      g->fields = g_list_remove(g->fields, f); retire(f); f = NULL;
      if (g->dead) { g_free(id); break; }
    }
    gboolean fresh = !f;
    if (!f) f = new_field(g, id);
    g_free(id); f->seen = TRUE;
    if (!fresh && version < f->version) continue;
    field_ref(f);
    gboolean changed = fresh || version != f->version;
    f->token = token; f->version = version;
    g_free(f->raw); f->raw = owned_text(ui_frame_field_text(frame, i, MC_UI_FIELD_RAW));
    f->known = ui_frame_field_value(frame, i, MC_UI_FIELD_SELECTION_KNOWN) == 1;
    f->anchor = ui_frame_field_value(frame, i, MC_UI_FIELD_ANCHOR); f->focus = ui_frame_field_value(frame, i, MC_UI_FIELD_FOCUS);
    f->marked = ui_frame_field_value(frame, i, MC_UI_FIELD_MARKED_START);
    f->multiline = ui_frame_field_value(frame, i, MC_UI_FIELD_MULTILINE) == 1;
    gboolean focused = ui_frame_field_value(frame, i, MC_UI_FIELD_FOCUSED) == 1;
    gboolean focus_transition = focused && !f->focused; f->focused = focused;
    f->clip_x = ui_frame_field_number(frame, i, MC_UI_FIELD_CLIP_X) - ui_frame_field_number(frame, i, MC_UI_FIELD_X);
    f->clip_y = ui_frame_field_number(frame, i, MC_UI_FIELD_CLIP_Y) - ui_frame_field_number(frame, i, MC_UI_FIELD_Y);
    f->clip_width = ui_frame_field_number(frame, i, MC_UI_FIELD_CLIP_WIDTH);
    f->clip_height = ui_frame_field_number(frame, i, MC_UI_FIELD_CLIP_HEIGHT);
    f->suppress++;
    gtk_text_view_set_editable(GTK_TEXT_VIEW(f->view), ui_frame_field_value(frame, i, MC_UI_FIELD_ENABLED) == 1 && ui_frame_field_value(frame, i, MC_UI_FIELD_READ_ONLY) == 0);
    gtk_widget_set_sensitive(f->view, ui_frame_field_value(frame, i, MC_UI_FIELD_ENABLED) == 1);
    char *label = owned_text(ui_frame_field_text(frame, i, MC_UI_FIELD_LABEL));
    char *tip = owned_text(ui_frame_field_text(frame, i, MC_UI_FIELD_TOOLTIP));
    char *error = owned_text(ui_frame_field_text(frame, i, MC_UI_FIELD_ERROR));
    atk_object_set_name(gtk_widget_get_accessible(f->view), label);
    atk_object_set_description(gtk_widget_get_accessible(f->view), *error ? error : tip);
    gtk_widget_set_tooltip_text(f->view, *error ? error : tip); g_free(label); g_free(tip); g_free(error);
    int rgb = ui_frame_field_value(frame, i, MC_UI_FIELD_COLOR), weight = ui_frame_field_value(frame, i, MC_UI_FIELD_WEIGHT);
    char number[G_ASCII_DTOSTR_BUF_SIZE], alpha[G_ASCII_DTOSTR_BUF_SIZE];
    g_ascii_dtostr(number, sizeof(number), ui_frame_field_number(frame, i, MC_UI_FIELD_FONT_SIZE));
    g_ascii_dtostr(alpha, sizeof(alpha), ui_frame_field_number(frame, i, MC_UI_FIELD_OPACITY));
    char *css = g_strdup_printf("textview, textview text { background: transparent; color: rgba(%d,%d,%d,%s); font-family: Sans; font-size: %spx; font-weight: %d; padding: 0; border: 0; }", (rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255, alpha, number, weight == MC_UI_WEIGHT_SEMIBOLD ? 600 : weight == MC_UI_WEIGHT_BOLD ? 700 : weight == MC_UI_WEIGHT_MEDIUM ? 500 : 400);
    if (g_strcmp0(f->css_text, css)) {
      gtk_css_provider_load_from_data(f->css, css, -1, NULL);
      g_free(f->css_text); f->css_text = css;
    } else g_free(css);
    gtk_fixed_move(GTK_FIXED(g->fixed), f->view, (int)floor(ui_frame_field_number(frame, i, MC_UI_FIELD_X)), (int)floor(ui_frame_field_number(frame, i, MC_UI_FIELD_Y)));
    gtk_widget_set_size_request(f->view, MAX(1, (int)ceil(ui_frame_field_number(frame, i, MC_UI_FIELD_WIDTH))), MAX(1, (int)ceil(ui_frame_field_number(frame, i, MC_UI_FIELD_HEIGHT))));
    gtk_widget_show(f->view); f->suppress--;
    if (changed) sync_native(f);
    if (focus_transition && !f->dead && gtk_widget_get_sensitive(f->view)) {
      f->suppress++; gtk_widget_grab_focus(f->view); f->suppress--;
    }
    field_unref(f);
  }
  /* Destroying a native widget may reenter its owner. Never keep a list node
   * across retirement: a callback may have retired the entire remaining group. */
  while (!g->dead) {
    GList *unseen = NULL;
    for (GList *p = g->fields; p; p = p->next)
      if (!((Field *)p->data)->seen) { unseen = p; break; }
    if (!unseen) break;
    Field *f = unseen->data;
    g->fields = g_list_delete_link(g->fields, unseen);
    retire(f);
  }
  gboolean ok = !g->dead; group_unref(g); return ok;
}
GtkWidget *mc_linux_text_inputs_field(MCLinuxTextInputs *g, const char *id) {
  for (GList *p = g && !g->dead ? g->fields : NULL; p; p = p->next) { Field *f = p->data; if (!strcmp(f->id, id)) return f->view; }
  return NULL;
}
gboolean mc_linux_text_inputs_contains(MCLinuxTextInputs *g, GtkWidget *view) {
  return g && !g->dead && view && (view == g->fixed || gtk_widget_is_ancestor(view, g->fixed));
}
GtkWidget *mc_linux_text_inputs_active(MCLinuxTextInputs *g) {
  for (GList *p = g && !g->dead ? g->fields : NULL; p; p = p->next) {
    Field *f = p->data; if (f->focused) return f->view;
  }
  return NULL;
}
gboolean mc_linux_text_inputs_composing(MCLinuxTextInputs *g) {
  for (GList *p = g && !g->dead ? g->fields : NULL; p; p = p->next) if (((Field *)p->data)->composing) return TRUE;
  return FALSE;
}
gboolean mc_linux_text_inputs_history(MCLinuxTextInputs *g, GtkWidget *view, gboolean redo) {
  for (GList *p = g && !g->dead ? g->fields : NULL; p; p = p->next) {
    Field *f = p->data; if (f->view != view) continue;
    field_ref(f); gboolean ok = !f->composing && flush_field(f);
    if (ok && !f->dead) ok = emit(f, redo ? MC_UI_TEXT_REDO : MC_UI_TEXT_UNDO, 0, 0, NULL, 0, 0, 0);
    if (!f->dead) sync_native(f); field_unref(f); return ok;
  }
  return FALSE;
}
gboolean mc_linux_text_inputs_flush(MCLinuxTextInputs *g) {
  if (!g || g->dead) return FALSE;
  g->refs++; GPtrArray *fields = g_ptr_array_new_with_free_func(field_unref);
  for (GList *p = g->fields; p; p = p->next) g_ptr_array_add(fields, field_ref(p->data));
  gboolean ok = TRUE;
  for (guint i = 0; i < fields->len; i++) { Field *f = g_ptr_array_index(fields, i); if (!f->dead && !flush_field(f)) ok = FALSE; }
  ok = ok && !g->dead; g_ptr_array_unref(fields); group_unref(g); return ok;
}
