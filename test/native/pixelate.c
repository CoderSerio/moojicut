#include <assert.h>
#include <string.h>
#include "native/shared/pixelate.h"
int main(void) {
  /* Two source cells, padded row stride, a mask crossing their boundary. */
  uint8_t pixels[4 * 40], original[sizeof(pixels)];
  memset(pixels, 0xCC, sizeof(pixels));
  for (int y = 0; y < 4; y++) for (int x = 0; x < 8; x++) {
    uint8_t *p = pixels + y * 40 + x * 4;
    p[0] = p[1] = p[2] = x < 4 ? (x % 2 ? 200 : 0) : 240;
    p[3] = 255;
  }
  memcpy(original, pixels, sizeof(pixels));
  mc_pixelate_bgra(pixels, 8, 4, 40, 2, 1, 4, 2, 4);
  for (int y = 0; y < 4; y++) for (int x = 0; x < 8; x++) {
    uint8_t *p = pixels + y * 40 + x * 4;
    if (y >= 1 && y < 3 && x >= 2 && x < 6) {
      assert(p[0] == (x < 4 ? 100 : 240)); assert(p[1] == p[0] && p[2] == p[0] && p[3] == 255);
    } else assert(memcmp(p, original + y * 40 + x * 4, 4) == 0);
  }
  for (int y = 0; y < 4; y++) assert(memcmp(pixels + y * 40 + 32, original + y * 40 + 32, 8) == 0);
  /* Each subsequent effect samples the already composited scene. */
  memset(pixels, 80, sizeof(pixels));
  mc_pixelate_bgra(pixels, 8, 4, 40, -2, -1, 5, 3, 4);
  assert(pixels[0] == 80 && pixels[3] == 255 && pixels[3 * 4 + 3] == 80);
  memcpy(original, pixels, sizeof(pixels));
  mc_pixelate_bgra(pixels, 8, 4, 40, 0, 0, 8, 4, 0);
  assert(memcmp(pixels, original, sizeof(pixels)) == 0);
  return 0;
}
