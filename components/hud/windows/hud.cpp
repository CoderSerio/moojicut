#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define NOMINMAX
#include "hud.h"
#include "components/icons/shared/mc_icons.h"
#include "native/shared/editor_style.h"
#include <objidl.h>

#include <cwchar>
#include <gdiplus.h>
using namespace Gdiplus;
namespace {
struct Runtime {
  ULONG_PTR token = 0;
  Runtime() {
    GdiplusStartupInput input;
    GdiplusStartup(&token, &input, nullptr);
  }
  ~Runtime() {
    if (token)
      GdiplusShutdown(token);
  }
};
void ensure_runtime() {
  static Runtime runtime;
  (void)runtime;
}
void configure(Graphics &graphics) {
  graphics.SetSmoothingMode(SmoothingModeAntiAlias);
  graphics.SetPixelOffsetMode(PixelOffsetModeHighQuality);
  graphics.SetTextRenderingHint(TextRenderingHintAntiAliasGridFit);
}
void rounded(GraphicsPath &path, RectF rect, REAL radius) {
  REAL diameter = radius * 2;
  path.AddArc(rect.X, rect.Y, diameter, diameter, 180, 90);
  path.AddArc(rect.GetRight() - diameter, rect.Y, diameter, diameter, 270, 90);
  path.AddArc(rect.GetRight() - diameter, rect.GetBottom() - diameter, diameter, diameter, 0, 90);
  path.AddArc(rect.X, rect.GetBottom() - diameter, diameter, diameter, 90, 90);
  path.CloseFigure();
}
void fill_round(Graphics &graphics, RectF rect, REAL radius, Color color) {
  GraphicsPath path;
  rounded(path, rect, radius);
  SolidBrush brush(color);
  graphics.FillPath(&brush, &path);
}
void icon(Graphics &graphics, MCIcon name, RectF rect, float scale, BOOL disabled) {
  MCIconPath data = mc_icon_path(name);
  GraphicsPath path;
  REAL glyph = (name == MC_ICON_CHEVRON_UP || name == MC_ICON_CHEVRON_DOWN) ? 10.0f : 18.0f;
  REAL factor = glyph * scale / 24, x = rect.X + (rect.Width - glyph * scale) / 2,
       y = rect.Y + (rect.Height - glyph * scale) / 2;
  PointF cursor(0, 0);
  for (unsigned i = 0; i < data.count; i++) {
    const MCIconCommand &c = data.commands[i];
    PointF to(x + c.x1 * factor, y + c.y1 * factor);
    if (c.op == 'M') {
      path.StartFigure();
      cursor = to;
    } else if (c.op == 'L') {
      path.AddLine(cursor, to);
      cursor = to;
    } else if (c.op == 'C') {
      PointF end(x + c.x3 * factor, y + c.y3 * factor);
      path.AddBezier(cursor, to, PointF(x + c.x2 * factor, y + c.y2 * factor), end);
      cursor = end;
    } else if (c.op == 'F') {
      Color color = disabled ? Color((BYTE)(255*c.x1), 111, 106, 120) : Color((BYTE)(255*c.x1), 230, 227, 222);
      SolidBrush brush(color); graphics.FillPath(&brush, &path); path.Reset();
    } else if (c.op == 'Z')
      path.CloseFigure();
  }
  Pen pen(disabled ? Color(255, 111, 106, 120) : Color(255, 230, 227, 222), 1.5f * scale);
  pen.SetStartCap(LineCapRound);
  pen.SetEndCap(LineCapRound);
  pen.SetLineJoin(LineJoinRound);
  if (mc_icon_filled(name)) {
    SolidBrush brush(disabled ? Color(255, 111, 106, 120) : Color(255, 230, 227, 222));
    graphics.FillPath(&brush, &path);
  } else graphics.DrawPath(&pen, &path);
}
void text(Graphics &graphics, const wchar_t *value, RectF rect, float size, Color color,
          StringAlignment align) {
  Font font(L"Segoe UI", size, FontStyleRegular, UnitPixel);
  SolidBrush brush(color);
  StringFormat format;
  format.SetAlignment(align);
  format.SetLineAlignment(StringAlignmentCenter);
  format.SetFormatFlags(StringFormatFlagsNoWrap);
  graphics.DrawString(value, -1, &font, rect, &format, &brush);
}
} // namespace
extern "C" void mc_hud_card(HDC dc, const RECT *bounds, float scale, const wchar_t *hint) {
  /* Initialize GDI+ before constructing its drawing objects. */
  ensure_runtime();
  Graphics graphics(dc);
  configure(graphics);
  RectF rect((REAL)bounds->left, (REAL)bounds->top, (REAL)(bounds->right - bounds->left),
             (REAL)(bounds->bottom - bounds->top));
  for (int i = 5; i > 0; i--) {
    RectF shadow = rect;
    shadow.Inflate(i * scale, i * scale);
    shadow.Y += 2 * scale;
    fill_round(graphics, shadow, (12 + i) * scale, Color(8, 0, 0, 0));
  }
  fill_round(graphics, rect, 12 * scale, Color(255, 41, 39, 48));
  GraphicsPath outline;
  RectF edge = rect;
  edge.Inflate(-.5f * scale, -.5f * scale);
  rounded(outline, edge, 11.5f * scale);
  Pen border(Color(255, 65, 61, 73), scale);
  graphics.DrawPath(&border, &outline);
  Pen divider(Color(255, 76, 71, 83), scale);
  const int separators[1] = {280};
  for (int offset : separators)
    graphics.DrawLine(&divider, rect.X + offset * scale, rect.Y + 17 * scale, rect.X + offset * scale,
                      rect.Y + 31 * scale);
  (void)hint;
}
extern "C" void mc_hud_button(HDC dc, const RECT *bounds, int kind, int value, BOOL selected, BOOL hovered,
                              BOOL pressed, BOOL focused, BOOL disabled, float scale) {
  ensure_runtime();
  Graphics graphics(dc);
  configure(graphics);
  RectF rect((REAL)bounds->left, (REAL)bounds->top, (REAL)(bounds->right - bounds->left),
             (REAL)(bounds->bottom - bounds->top));
  SolidBrush base(Color(255, 41, 39, 48));
  graphics.FillRectangle(&base, rect);
  RectF highlight = rect;
  highlight.Inflate(-1 * scale, -1 * scale);
  if (!disabled && (selected || hovered || pressed))
    fill_round(graphics, highlight, 7 * scale,
               pressed    ? Color(255, 91, 85, 101)
               : selected ? Color(255, 75, 70, 84)
                          : Color(255, 57, 53, 65));
  if (focused && !disabled) {
    GraphicsPath outline;
    rounded(outline, highlight, 7 * scale);
    Pen ring(Color(255, 156, 149, 167), scale);
    graphics.DrawPath(&ring, &outline);
  }
  if (kind >= 0 && kind < MC_ICON_COUNT)
    icon(graphics, (MCIcon)kind, rect, scale, disabled);
  else if (kind == MC_HUD_COLOR) {
    SolidBrush swatch(Color(255, (BYTE)(value >> 16), (BYTE)(value >> 8), (BYTE)value));
    REAL edge_width = focused && !disabled ? 2 * scale : scale;
    REAL diameter = editor_style_swatch_size() * scale - edge_width;
    RectF circle(rect.X + (rect.Width - diameter) / 2, rect.Y + (rect.Height - diameter) / 2, diameter, diameter);
    graphics.FillEllipse(&swatch, circle);
    Pen edge(focused && !disabled ? Color(255, 194, 176, 242) : Color(90, 255, 255, 255), edge_width);
    graphics.DrawEllipse(&edge, circle);
  } else if (kind == MC_HUD_COLOR_LABEL) {
    text(graphics, L"颜色", rect, 11 * scale,
         disabled ? Color(255, 111, 105, 120) : Color(255, 184, 177, 191), StringAlignmentNear);
  } else if (kind == MC_HUD_STROKE) {
    wchar_t label[32];
    swprintf_s(label, 32, L"线宽  %d px", value);
    text(graphics, label, rect, 12 * scale, Color(255, 222, 217, 228), StringAlignmentCenter);
  } else if (kind == MC_HUD_OPACITY) {
    wchar_t label[40];
    swprintf_s(label, 40, L"不透明度  %d%%", value);
    text(graphics, label, rect, 12 * scale, Color(255, 222, 217, 228), StringAlignmentCenter);
  } else if (kind == MC_HUD_SHAPE) {
    const MCIcon outline[] = {MC_ICON_RECTANGLE, MC_ICON_ELLIPSE, MC_ICON_MOSAIC};
    const MCIcon cover[] = {MC_ICON_REDACT, MC_ICON_COVER_ELLIPSE, MC_ICON_MOSAIC};
    int shape = value % 10;
    if (shape < 0 || shape > 2) shape = 0;
    text(graphics, L"形状", RectF(rect.X, rect.Y, 44 * scale, rect.Height), 12 * scale,
         Color(255, 222, 217, 228), StringAlignmentCenter);
    icon(graphics, value / 10 == 4 ? cover[shape] : outline[shape],
         RectF(rect.X + 44 * scale, rect.Y, 32 * scale, rect.Height), scale, disabled);
  } else if (kind == MC_HUD_BLOCK) {
    wchar_t label[32];
    swprintf_s(label, 32, L"颗粒  %d", value);
    text(graphics, label, rect, 12 * scale, Color(255, 222, 217, 228), StringAlignmentCenter);
  } else if (kind == MC_HUD_FONT) {
    wchar_t label[32];
    swprintf_s(label, 32, L"字号  %d", value);
    text(graphics, label, rect, 12 * scale, Color(255, 222, 217, 228), StringAlignmentCenter);
  }
}
extern "C" void mc_hud_frame(HDC dc, const RECT *bounds, BOOL handles, float scale) {
  ensure_runtime();
  Graphics graphics(dc);
  configure(graphics);
  REAL left = (REAL)bounds->left + .5f, top = (REAL)bounds->top + .5f, right = (REAL)bounds->right + .5f,
       bottom = (REAL)bounds->bottom + .5f;
  Pen contrast(Color(160, 40, 34, 48), 2.5f * scale), line(Color(255, 194, 191, 186), scale);
  RectF rect(left, top, right - left, bottom - top);
  graphics.DrawRectangle(&contrast, rect);
  graphics.DrawRectangle(&line, rect);
  if (handles) {
    PointF points[8] = {
        {left, top},     {(left + right) / 2, top},    {right, top},   {right, (top + bottom) / 2},
        {right, bottom}, {(left + right) / 2, bottom}, {left, bottom}, {left, (top + bottom) / 2}};
    for (PointF point : points) {
      RectF handle(point.X - 2.5f * scale, point.Y - 2.5f * scale, 5 * scale, 5 * scale);
      fill_round(graphics, handle, 1.5f * scale, Color(255, 250, 245, 235));
    }
  }
}
