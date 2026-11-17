#ifndef MOOJICUT_PIXELATE_H
#define MOOJICUT_PIXELATE_H
#include <stdint.h>
#include <stddef.h>
/* Pixel backend only: little-endian Cairo ARGB32 / Win32 BGRX, opaque desktop.
 * Cells align to source pixels, independent of viewport, scale or crop. Sample
 * the composited scene, including earlier annotations/masks; write only inside
 * the requested region. No document, gesture or UI policy lives here. */
static void mc_pixelate_bgra(uint8_t *pixels, int width, int height, int stride,
                            int x, int y, int w, int h, int block) {
  if (!pixels || width <= 0 || height <= 0 || stride < width * 4 || block < 4 || block > 48 || w <= 0 || h <= 0) return;
  int left = x < 0 ? 0 : x, top = y < 0 ? 0 : y;
  int right = x + w > width ? width : x + w, bottom = y + h > height ? height : y + h;
  for (int by = top / block * block; by < bottom; by += block)
    for (int bx = left / block * block; bx < right; bx += block) {
      int ex = bx + block < width ? bx + block : width, ey = by + block < height ? by + block : height;
      uint64_t sum[3] = {0, 0, 0}, count = (uint64_t)(ex - bx) * (ey - by);
      for (int py = by; py < ey; py++)
        for (int px = bx; px < ex; px++) {
          const uint8_t *p = pixels + (size_t)py * stride + (size_t)px * 4;
          for (int c = 0; c < 3; c++) sum[c] += p[c];
        }
      for (int py = by < top ? top : by; py < ey && py < bottom; py++)
        for (int px = bx < left ? left : bx; px < ex && px < right; px++) {
          uint8_t *p = pixels + (size_t)py * stride + (size_t)px * 4;
          for (int c = 0; c < 3; c++) p[c] = (uint8_t)((sum[c] + count / 2) / count);
          p[3] = 255;
        }
    }
}
#endif
