#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include "shared_canvas_accessibility.h"
#include "bindings/c/ui_frame.h"
#include <oleacc.h>
#include <oleauto.h>
#include <limits.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

typedef struct {
  LONG child; wchar_t *identifier;
  BOOL value_changed, focus_changed, state_changed, name_changed, location_changed;
} AccessibleNode;
typedef struct AccessibleEnumeration AccessibleEnumeration;
static void free_enumeration(AccessibleEnumeration *enumeration);
struct MCCanvasAccessible {
  IAccessible base;
  LONG references, next_child;
  HWND window;
  int32_t frame;
  AccessibleNode *nodes;
  int count;
  MCCanvasAccessibleAction action;
  void *context;
  BOOL reordered;
  AccessibleEnumeration *enumeration;
};
static MCCanvasAccessible *owner(IAccessible *self) { return (MCCanvasAccessible *)self; }
static HRESULT enumeration(MCCanvasAccessible *a, void **out);
static ULONG STDMETHODCALLTYPE add_ref(IAccessible *self) { return (ULONG)InterlockedIncrement(&owner(self)->references); }
static void free_nodes(AccessibleNode *nodes, int count) {
  for (int i = 0; i < count; i++) free(nodes[i].identifier);
  free(nodes);
}
static ULONG STDMETHODCALLTYPE release(IAccessible *self) {
  MCCanvasAccessible *a = owner(self);
  LONG count = InterlockedDecrement(&a->references);
  if (!count) { free_enumeration(a->enumeration); free_nodes(a->nodes, a->count); free(a); }
  return (ULONG)count;
}
static HRESULT STDMETHODCALLTYPE query(IAccessible *self, REFIID iid, void **out) {
  if (!out) return E_POINTER; *out = NULL;
  if (IsEqualIID(iid, &IID_IUnknown) || IsEqualIID(iid, &IID_IDispatch) || IsEqualIID(iid, &IID_IAccessible)) {
    *out = self; add_ref(self); return S_OK;
  }
  if (IsEqualIID(iid, &IID_IEnumVARIANT)) return enumeration(owner(self), out);
  return E_NOINTERFACE;
}
struct AccessibleEnumeration {
  IEnumVARIANT base;
  LONG references;
  /* Non-NULL only for the provider's stable primary enumeration interface.
   * Clones are independent COM objects with their own IUnknown identity. */
  MCCanvasAccessible *accessible;
  LONG *children;
  ULONG count, index;
};
static void free_enumeration(AccessibleEnumeration *e) { if (e) { free(e->children); free(e); } }
static AccessibleEnumeration *enumerator(IEnumVARIANT *self) { return (AccessibleEnumeration *)self; }
static ULONG STDMETHODCALLTYPE enum_add_ref(IEnumVARIANT *self) {
  AccessibleEnumeration *e = enumerator(self);
  return e->accessible ? add_ref(&e->accessible->base) : (ULONG)InterlockedIncrement(&e->references);
}
static ULONG STDMETHODCALLTYPE enum_release(IEnumVARIANT *self) {
  AccessibleEnumeration *e = enumerator(self);
  if (e->accessible) return release(&e->accessible->base);
  LONG refs = InterlockedDecrement(&e->references);
  if (!refs) free_enumeration(e); return (ULONG)refs;
}
static HRESULT STDMETHODCALLTYPE enum_query(IEnumVARIANT *self, REFIID iid, void **out) {
  if (!out) return E_POINTER; *out = NULL;
  AccessibleEnumeration *e = enumerator(self);
  if (IsEqualIID(iid, &IID_IEnumVARIANT) || (!e->accessible && IsEqualIID(iid, &IID_IUnknown))) {
    *out = self; enum_add_ref(self); return S_OK;
  }
  return e->accessible ? query(&e->accessible->base, iid, out) : E_NOINTERFACE;
}
static HRESULT STDMETHODCALLTYPE enum_next(IEnumVARIANT *self, ULONG count, VARIANT *items, ULONG *fetched) {
  if (fetched) *fetched = 0;
  if ((count && !items) || (count > 1 && !fetched)) return E_POINTER;
  AccessibleEnumeration *e = enumerator(self); ULONG done = 0;
  while (done < count && e->index < e->count) {
    VariantInit(&items[done]); items[done].vt = VT_I4; items[done].lVal = e->children[e->index++]; done++;
  }
  if (fetched) *fetched = done; return done == count ? S_OK : S_FALSE;
}
static HRESULT STDMETHODCALLTYPE enum_skip(IEnumVARIANT *self, ULONG count) {
  AccessibleEnumeration *e = enumerator(self); ULONG available = e->count - e->index;
  e->index += min(count, available); return count <= available ? S_OK : S_FALSE;
}
static HRESULT STDMETHODCALLTYPE enum_reset(IEnumVARIANT *self) {
  AccessibleEnumeration *e = enumerator(self);
  if (e->accessible) {
    MCCanvasAccessible *a = e->accessible;
    if (!a->window) return CO_E_OBJNOTCONNECTED;
    LONG *children = a->count ? calloc((size_t)a->count, sizeof(LONG)) : NULL;
    if (a->count && !children) return E_OUTOFMEMORY;
    for (int i = 0; i < a->count; i++) children[i] = a->nodes[i].child;
    free(e->children); e->children = children; e->count = (ULONG)a->count;
  }
  e->index = 0; return S_OK;
}
static HRESULT STDMETHODCALLTYPE enum_clone(IEnumVARIANT *self, IEnumVARIANT **out);
static IEnumVARIANTVtbl enum_methods = {enum_query, enum_add_ref, enum_release, enum_next, enum_skip, enum_reset, enum_clone};
static AccessibleEnumeration *make_enumeration(ULONG count) {
  AccessibleEnumeration *e = calloc(1, sizeof(*e)); if (!e) return NULL;
  e->children = count ? calloc(count, sizeof(LONG)) : NULL;
  if (count && !e->children) { free(e); return NULL; }
  e->base.lpVtbl = &enum_methods; e->references = 1; e->count = count; return e;
}
static HRESULT enumeration(MCCanvasAccessible *a, void **out) {
  if (!a->window) return CO_E_OBJNOTCONNECTED;
  if (!a->enumeration) {
    AccessibleEnumeration *e = make_enumeration(0); if (!e) return E_OUTOFMEMORY;
    e->accessible = a;
    HRESULT reset = enum_reset(&e->base);
    if (FAILED(reset)) { free_enumeration(e); return reset; }
    a->enumeration = e;
  }
  /* QueryInterface is identity navigation, not a fresh iterator operation.
   * AccessibleChildren resets this interface to snapshot the current tree. */
  *out = &a->enumeration->base; add_ref(&a->base); return S_OK;
}
static HRESULT STDMETHODCALLTYPE enum_clone(IEnumVARIANT *self, IEnumVARIANT **out) {
  if (!out) return E_POINTER; *out = NULL; AccessibleEnumeration *current = enumerator(self);
  AccessibleEnumeration *copy = make_enumeration(current->count); if (!copy) return E_OUTOFMEMORY;
  if (current->count) memcpy(copy->children, current->children, (size_t)current->count * sizeof(LONG));
  copy->index = current->index; *out = &copy->base; return S_OK;
}
static HRESULT STDMETHODCALLTYPE type_count(IAccessible *self, UINT *out) { (void)self; if (!out) return E_POINTER; *out = 0; return S_OK; }
static HRESULT STDMETHODCALLTYPE type_info(IAccessible *self, UINT index, LCID locale, ITypeInfo **out) {
  (void)self; (void)index; (void)locale; if (!out) return E_POINTER; *out = NULL; return E_NOTIMPL;
}
static HRESULT STDMETHODCALLTYPE ids(IAccessible *self, REFIID iid, LPOLESTR *names, UINT count, LCID locale, DISPID *out) {
  (void)self; (void)iid; (void)names; (void)count; (void)locale; (void)out; return E_NOTIMPL;
}
static HRESULT STDMETHODCALLTYPE invoke(IAccessible *self, DISPID id, REFIID iid, LCID locale, WORD flags,
                                       DISPPARAMS *params, VARIANT *result, EXCEPINFO *error, UINT *argument) {
  (void)self; (void)id; (void)iid; (void)locale; (void)flags; (void)params; (void)result; (void)error; (void)argument; return E_NOTIMPL;
}
static int node(MCCanvasAccessible *a, VARIANT child) {
  if (child.vt != VT_I4 || !a->window || !IsWindow(a->window)) return -2;
  if (child.lVal == CHILDID_SELF) return -1;
  for (int i = 0; i < a->count; i++) if (a->nodes[i].child == child.lVal) return i;
  return -2;
}
static HRESULT STDMETHODCALLTYPE parent(IAccessible *self, IDispatch **out) {
  if (!out) return E_POINTER; *out = NULL; HWND window = owner(self)->window;
  if (!window || !IsWindow(window)) return CO_E_OBJNOTCONNECTED;
  HWND p = GetParent(window); if (!p) return S_FALSE;
  /* This API takes DWORD object IDs, while OBJID_CLIENT is a signed LONG.
   * Preserve the documented bit pattern explicitly under MSVC /W4 /WX. */
  return AccessibleObjectFromWindow(p, (DWORD)OBJID_CLIENT, &IID_IDispatch, (void **)out);
}
static HRESULT STDMETHODCALLTYPE child_count(IAccessible *self, LONG *out) {
  if (!out) return E_POINTER; MCCanvasAccessible *a = owner(self);
  *out = a->window ? a->count : 0; return a->window ? S_OK : CO_E_OBJNOTCONNECTED;
}
static HRESULT STDMETHODCALLTYPE child_object(IAccessible *self, VARIANT child, IDispatch **out) {
  if (!out) return E_POINTER; *out = NULL;
  return node(owner(self), child) == -2 ? E_INVALIDARG : S_FALSE;
}
static HRESULT text_value(MCCanvasAccessible *a, int i, int field, BSTR *out) {
  moonbit_string_t value = ui_frame_semantic_text(a->frame, i, field);
  int length = Moonbit_array_length(value);
  *out = SysAllocStringLen((const OLECHAR *)value, (UINT)length); moonbit_decref(value);
  return *out ? S_OK : E_OUTOFMEMORY;
}
static HRESULT STDMETHODCALLTYPE name(IAccessible *self, VARIANT child, BSTR *out) {
  if (!out) return E_POINTER; *out = NULL; MCCanvasAccessible *a = owner(self); int i = node(a, child);
  if (i == -2) return E_INVALIDARG;
  if (i == -1) { *out = SysAllocString(L"Canvas"); return *out ? S_OK : E_OUTOFMEMORY; }
  return text_value(a, i, MC_UI_SEM_LABEL, out);
}
static HRESULT STDMETHODCALLTYPE value(IAccessible *self, VARIANT child, BSTR *out) {
  if (!out) return E_POINTER; *out = NULL; MCCanvasAccessible *a = owner(self); int i = node(a, child);
  if (i == -2) return E_INVALIDARG; if (i < 0) return S_FALSE;
  int type = ui_frame_semantic_value(a->frame, i, MC_UI_SEM_VALUE_TYPE);
  if (type == MC_UI_VALUE_TEXT) return text_value(a, i, MC_UI_SEM_VALUE_TEXT, out);
  if (type == MC_UI_VALUE_NONE) return S_FALSE;
  double n = ui_frame_semantic_number(a->frame, i, MC_UI_SEM_VALUE);
  wchar_t buffer[64];
  if (type == MC_UI_VALUE_BOOL) wcscpy_s(buffer, 64, n ? L"true" : L"false");
  else swprintf_s(buffer, 64, L"%.15g", n);
  *out = SysAllocString(buffer); return *out ? S_OK : E_OUTOFMEMORY;
}
static HRESULT STDMETHODCALLTYPE description(IAccessible *self, VARIANT child, BSTR *out) {
  if (!out) return E_POINTER; *out = NULL; MCCanvasAccessible *a = owner(self); int i = node(a, child);
  if (i == -2) return E_INVALIDARG; if (i < 0) return S_FALSE;
  return text_value(a, i, MC_UI_SEM_TOOLTIP, out);
}
static HRESULT STDMETHODCALLTYPE role(IAccessible *self, VARIANT child, VARIANT *out) {
  if (!out) return E_POINTER; VariantInit(out); MCCanvasAccessible *a = owner(self); int i = node(a, child);
  if (i == -2) return E_INVALIDARG;
  int r = i < 0 ? MC_UI_ROLE_GROUP : ui_frame_semantic_value(a->frame, i, MC_UI_SEM_ROLE);
  out->vt = VT_I4; out->lVal = r == MC_UI_ROLE_BUTTON ? ROLE_SYSTEM_PUSHBUTTON : r == MC_UI_ROLE_SLIDER ? ROLE_SYSTEM_SLIDER :
      r == MC_UI_ROLE_CHECKBOX ? ROLE_SYSTEM_CHECKBUTTON : r == MC_UI_ROLE_TEXT ? ROLE_SYSTEM_STATICTEXT : ROLE_SYSTEM_GROUPING;
  return S_OK;
}
static HRESULT STDMETHODCALLTYPE state(IAccessible *self, VARIANT child, VARIANT *out) {
  if (!out) return E_POINTER; VariantInit(out); MCCanvasAccessible *a = owner(self); int i = node(a, child);
  if (i == -2) return E_INVALIDARG;
  out->vt = VT_I4; out->lVal = 0;
  if (!IsWindowVisible(a->window)) out->lVal |= STATE_SYSTEM_INVISIBLE;
  if (i < 0) { out->lVal |= STATE_SYSTEM_FOCUSABLE; if (GetFocus() == a->window) out->lVal |= STATE_SYSTEM_FOCUSED; return S_OK; }
  int r = ui_frame_semantic_value(a->frame, i, MC_UI_SEM_ROLE);
  if (r == MC_UI_ROLE_BUTTON || r == MC_UI_ROLE_SLIDER || r == MC_UI_ROLE_CHECKBOX) out->lVal |= STATE_SYSTEM_FOCUSABLE;
  if (!ui_frame_semantic_value(a->frame, i, MC_UI_SEM_ENABLED)) out->lVal |= STATE_SYSTEM_UNAVAILABLE;
  if (GetFocus() == a->window && ui_frame_semantic_value(a->frame, i, MC_UI_SEM_FOCUSED)) out->lVal |= STATE_SYSTEM_FOCUSED;
  if (r == MC_UI_ROLE_CHECKBOX && ui_frame_semantic_value(a->frame, i, MC_UI_SEM_VALUE_TYPE) == MC_UI_VALUE_BOOL &&
      ui_frame_semantic_number(a->frame, i, MC_UI_SEM_VALUE)) out->lVal |= STATE_SYSTEM_CHECKED;
  return S_OK;
}
static HRESULT STDMETHODCALLTYPE help_topic(IAccessible *self, BSTR *file, VARIANT child, LONG *topic) {
  (void)self; (void)child; if (!file || !topic) return E_POINTER; *file = NULL; *topic = 0; return S_FALSE;
}
static HRESULT STDMETHODCALLTYPE shortcut(IAccessible *self, VARIANT child, BSTR *out) {
  if (!out) return E_POINTER; *out = NULL; return node(owner(self), child) == -2 ? E_INVALIDARG : S_FALSE;
}
static HRESULT STDMETHODCALLTYPE focus(IAccessible *self, VARIANT *out) {
  if (!out) return E_POINTER; VariantInit(out); MCCanvasAccessible *a = owner(self);
  if (!a->window) return CO_E_OBJNOTCONNECTED;
  if (GetFocus() != a->window) return S_FALSE;
  out->vt = VT_I4; out->lVal = CHILDID_SELF;
  for (int i = 0; i < a->count; i++) if (ui_frame_semantic_value(a->frame, i, MC_UI_SEM_FOCUSED)) { out->lVal = a->nodes[i].child; break; }
  return S_OK;
}
static HRESULT STDMETHODCALLTYPE selection(IAccessible *self, VARIANT *out) {
  (void)self; if (!out) return E_POINTER; VariantInit(out); return S_FALSE;
}
static BOOL actionable(MCCanvasAccessible *a, int i) {
  if (i < 0 || !ui_frame_semantic_value(a->frame, i, MC_UI_SEM_ENABLED)) return FALSE;
  int r = ui_frame_semantic_value(a->frame, i, MC_UI_SEM_ROLE);
  return r == MC_UI_ROLE_BUTTON || r == MC_UI_ROLE_SLIDER || r == MC_UI_ROLE_CHECKBOX;
}
static HRESULT STDMETHODCALLTYPE default_action(IAccessible *self, VARIANT child, BSTR *out) {
  if (!out) return E_POINTER; *out = NULL; MCCanvasAccessible *a = owner(self); int i = node(a, child);
  if (i == -2) return E_INVALIDARG; if (!actionable(a, i)) return S_FALSE;
  *out = SysAllocString(L"Activate"); return *out ? S_OK : E_OUTOFMEMORY;
}
static HRESULT STDMETHODCALLTYPE select_child(IAccessible *self, LONG flags, VARIANT child) {
  (void)self; (void)flags; (void)child; return E_NOTIMPL;
}
static HRESULT STDMETHODCALLTYPE location(IAccessible *self, LONG *x, LONG *y, LONG *width, LONG *height, VARIANT child) {
  if (!x || !y || !width || !height) return E_POINTER;
  *x = *y = *width = *height = 0; MCCanvasAccessible *a = owner(self); int i = node(a, child);
  if (i == -2) return E_INVALIDARG;
  RECT r; GetClientRect(a->window, &r); POINT origin = {0}; ClientToScreen(a->window, &origin);
  if (i >= 0) {
    UINT dpi = GetDpiForWindow(a->window); double scale = (dpi ? dpi : 96) / 96.0;
    r.left = (LONG)floor(ui_frame_semantic_number(a->frame, i, MC_UI_SEM_X) * scale + .5);
    r.top = (LONG)floor(ui_frame_semantic_number(a->frame, i, MC_UI_SEM_Y) * scale + .5);
    r.right = r.left + (LONG)floor(ui_frame_semantic_number(a->frame, i, MC_UI_SEM_WIDTH) * scale + .5);
    r.bottom = r.top + (LONG)floor(ui_frame_semantic_number(a->frame, i, MC_UI_SEM_HEIGHT) * scale + .5);
  }
  *x = origin.x + r.left; *y = origin.y + r.top; *width = r.right - r.left; *height = r.bottom - r.top; return S_OK;
}
static HRESULT STDMETHODCALLTYPE navigate(IAccessible *self, LONG direction, VARIANT start, VARIANT *out) {
  if (!out) return E_POINTER; VariantInit(out); MCCanvasAccessible *a = owner(self); int i = node(a, start), target = -1;
  if (i == -2) return E_INVALIDARG;
  if (i < 0 && direction == NAVDIR_FIRSTCHILD && a->count) target = 0;
  else if (i < 0 && direction == NAVDIR_LASTCHILD && a->count) target = a->count - 1;
  else if (i >= 0 && direction == NAVDIR_NEXT && i + 1 < a->count) target = i + 1;
  else if (i >= 0 && direction == NAVDIR_PREVIOUS && i > 0) target = i - 1;
  if (target < 0) return S_FALSE;
  out->vt = VT_I4; out->lVal = a->nodes[target].child; return S_OK;
}
static HRESULT STDMETHODCALLTYPE hit_test(IAccessible *self, LONG x, LONG y, VARIANT *out) {
  if (!out) return E_POINTER; VariantInit(out); MCCanvasAccessible *a = owner(self);
  if (!a->window) return CO_E_OBJNOTCONNECTED;
  VARIANT child; VariantInit(&child); child.vt = VT_I4;
  LONG left, top, width, height;
  for (int i = a->count - 1; i >= -1; i--) {
    child.lVal = i < 0 ? CHILDID_SELF : a->nodes[i].child;
    if (SUCCEEDED(location(self, &left, &top, &width, &height, child)) && x >= left && y >= top && x < left + width && y < top + height) {
      *out = child; return S_OK;
    }
  }
  return S_FALSE;
}
static HRESULT STDMETHODCALLTYPE perform(IAccessible *self, VARIANT child) {
  MCCanvasAccessible *a = owner(self); int i = node(a, child);
  if (i == -2 || !actionable(a, i) || !a->action) return E_INVALIDARG;
  moonbit_string_t identifier = ui_frame_semantic_text(a->frame, i, MC_UI_SEM_ID);
  /* A focus callback can synchronously destroy the canvas. Recheck the same
   * stable child before dispatch, and keep the identifier independently owned. */
  SetFocus(a->window);
  i = node(a, child);
  if (i == -2 || !actionable(a, i) || !a->action) { moonbit_decref(identifier); return E_INVALIDARG; }
  a->action(a->context, identifier, (size_t)Moonbit_array_length(identifier));
  moonbit_decref(identifier); return S_OK;
}
static HRESULT STDMETHODCALLTYPE put_name(IAccessible *self, VARIANT child, BSTR text) { (void)self; (void)child; (void)text; return E_NOTIMPL; }
static IAccessibleVtbl methods = {
  query, add_ref, release, type_count, type_info, ids, invoke, parent, child_count, child_object,
  name, value, description, role, state, description, help_topic, shortcut, focus, selection,
  default_action, select_child, location, navigate, hit_test, perform, put_name, put_name
};
MCCanvasAccessible *mc_canvas_accessible_create(HWND window, MCCanvasAccessibleAction action, void *context) {
  MCCanvasAccessible *a = calloc(1, sizeof(*a)); if (!a) return NULL;
  a->base.lpVtbl = &methods; a->references = 1; a->window = window; a->action = action; a->context = context;
  return a;
}
static BOOL text_changed(int32_t frame, int index, int32_t previous, int old_index, int field) {
  moonbit_string_t current = ui_frame_semantic_text(frame, index, field);
  moonbit_string_t old = ui_frame_semantic_text(previous, old_index, field);
  BOOL changed = Moonbit_array_length(current) != Moonbit_array_length(old) ||
      memcmp(current, old, (size_t)Moonbit_array_length(current) * sizeof(uint16_t)) != 0;
  moonbit_decref(current); moonbit_decref(old); return changed;
}
BOOL mc_canvas_accessible_frame(MCCanvasAccessible *a, int32_t frame) {
  if (!a || !a->window) return FALSE;
  int count = frame ? ui_frame_semantic_count(frame) : 0;
  if (count < 0 || a->next_child > LONG_MAX - count) return FALSE;
  AccessibleNode *nodes = count ? calloc((size_t)count, sizeof(*nodes)) : NULL;
  if (count && !nodes) return FALSE;
  LONG next = a->next_child; BOOL changed = count != a->count;
  for (int i = 0; i < count; i++) {
    moonbit_string_t id = ui_frame_semantic_text(frame, i, MC_UI_SEM_ID); int length = Moonbit_array_length(id);
    nodes[i].identifier = calloc((size_t)length + 1, sizeof(wchar_t));
    if (nodes[i].identifier) memcpy(nodes[i].identifier, id, (size_t)length * sizeof(wchar_t));
    moonbit_decref(id);
    if (!nodes[i].identifier) { free_nodes(nodes, count); return FALSE; }
    int previous = -1;
    for (int j = 0; j < a->count; j++) if (!wcscmp(nodes[i].identifier, a->nodes[j].identifier)) { nodes[i].child = a->nodes[j].child; previous = j; break; }
    nodes[i].focus_changed = ui_frame_semantic_value(frame, i, MC_UI_SEM_FOCUSED) &&
        (previous < 0 || !ui_frame_semantic_value(a->frame, previous, MC_UI_SEM_FOCUSED));
    if (previous >= 0) {
      int type = ui_frame_semantic_value(frame, i, MC_UI_SEM_VALUE_TYPE);
      nodes[i].value_changed = type != ui_frame_semantic_value(a->frame, previous, MC_UI_SEM_VALUE_TYPE) ||
          ui_frame_semantic_number(frame, i, MC_UI_SEM_VALUE) != ui_frame_semantic_number(a->frame, previous, MC_UI_SEM_VALUE);
      if (type == MC_UI_VALUE_TEXT && !nodes[i].value_changed) nodes[i].value_changed = text_changed(frame, i, a->frame, previous, MC_UI_SEM_VALUE_TEXT);
      nodes[i].state_changed = ui_frame_semantic_value(frame, i, MC_UI_SEM_ENABLED) != ui_frame_semantic_value(a->frame, previous, MC_UI_SEM_ENABLED) ||
          (type == MC_UI_VALUE_BOOL && nodes[i].value_changed);
      nodes[i].name_changed = text_changed(frame, i, a->frame, previous, MC_UI_SEM_LABEL);
      for (int f = MC_UI_SEM_X; f <= MC_UI_SEM_HEIGHT; f++)
        if (ui_frame_semantic_number(frame, i, f) != ui_frame_semantic_number(a->frame, previous, f)) nodes[i].location_changed = TRUE;
      if (ui_frame_semantic_value(frame, i, MC_UI_SEM_ROLE) != ui_frame_semantic_value(a->frame, previous, MC_UI_SEM_ROLE)) changed = TRUE;
    }
    if (!nodes[i].child) nodes[i].child = ++next;
    if (i >= a->count || nodes[i].child != a->nodes[i].child) changed = TRUE;
  }
  free_nodes(a->nodes, a->count); a->nodes = nodes; a->count = count; a->next_child = next; a->frame = frame;
  a->reordered = changed;
  return TRUE;
}
void mc_canvas_accessible_publish(MCCanvasAccessible *a) {
  if (!a || !a->window) return;
  add_ref(&a->base);
  int32_t frame = a->frame;
  if (a->reordered) { a->reordered = FALSE; NotifyWinEvent(EVENT_OBJECT_REORDER, a->window, OBJID_CLIENT, CHILDID_SELF); }
  for (int i = 0; a->window && a->frame == frame && i < a->count; i++) {
    LONG child = a->nodes[i].child;
    AccessibleNode changes = a->nodes[i];
    a->nodes[i].value_changed = a->nodes[i].focus_changed = a->nodes[i].state_changed = FALSE;
    a->nodes[i].name_changed = a->nodes[i].location_changed = FALSE;
    DWORD events[5]; int total = 0;
    if (changes.value_changed) events[total++] = EVENT_OBJECT_VALUECHANGE;
    if (changes.state_changed) events[total++] = EVENT_OBJECT_STATECHANGE;
    if (changes.name_changed) events[total++] = EVENT_OBJECT_NAMECHANGE;
    if (changes.location_changed) events[total++] = EVENT_OBJECT_LOCATIONCHANGE;
    if (changes.focus_changed) events[total++] = EVENT_OBJECT_FOCUS;
    for (int j = 0; a->window && a->frame == frame && j < total; j++) NotifyWinEvent(events[j], a->window, OBJID_CLIENT, child);
  }
  release(&a->base);
}
LRESULT mc_canvas_accessible_object(MCCanvasAccessible *a, WPARAM wp, LPARAM lp) {
  return a && a->window && (LONG)lp == OBJID_CLIENT ? LresultFromObject(&IID_IAccessible, wp, (IUnknown *)&a->base) : 0;
}
void mc_canvas_accessible_disconnect(MCCanvasAccessible *a) {
  if (!a) return;
  a->window = NULL; a->frame = 0; a->action = NULL; a->context = NULL;
  free_nodes(a->nodes, a->count); a->nodes = NULL; a->count = 0;
  release(&a->base);
}
