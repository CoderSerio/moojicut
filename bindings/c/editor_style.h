#ifndef MOOJICUT_EDITOR_STYLE_H
#define MOOJICUT_EDITOR_STYLE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Property numbers are also bit positions in editor_style_property_mask. */
enum {
  MC_STYLE_COLOR = 0,
  MC_STYLE_OPACITY = 1,
  MC_STYLE_STROKE = 2,
  MC_STYLE_FONT = 3,
  MC_STYLE_SHAPE = 4,
  MC_STYLE_BLOCK = 5,
  MC_STYLE_PROPERTY_COUNT = 6
};
enum {
  MC_STYLE_TOOL_SELECT = 0,
  MC_STYLE_TOOL_RECTANGLE = 1,
  MC_STYLE_TOOL_ARROW = 2,
  MC_STYLE_TOOL_TEXT = 3,
  MC_STYLE_TOOL_COVER = 4
};

/* Tool availability and numeric domains come from the MoonBit core.
 * Unknown tools/properties return zero. Step is a UI increment, not rounding:
 * fractional stroke/font values already accepted by documents remain valid. */
int32_t editor_style_property_mask(int32_t tool);
int32_t editor_style_visible_mask(int32_t tool, int32_t shape);
int32_t editor_style_shape_count(int32_t tool);
/* Logical space between complete property groups, not between their children. */
int32_t editor_style_group_gap(void);
/* Circular color control diameter / input bounds in logical points. */
int32_t editor_style_swatch_size(void);
double editor_style_min(int32_t property);
double editor_style_max(int32_t property);
double editor_style_step(int32_t property);
double editor_style_default(int32_t property);

/* Each editor handle owns independent per-tool style records in MoonBit.
 * Create returns a positive handle, or zero if no handle can be allocated.
 * Get returns complete style fields even when a tool cannot edit that field;
 * unsupported fields retain their defaults. Invalid handles/tools/properties
 * return zero. The cover starts with RGB 0x111111; other tools use coral.
 * Set returns 1 on success, 0 for unsupported fields or invalid input. */
int32_t editor_style_create(void);
double editor_style_get(int32_t handle, int32_t tool, int32_t property);
int32_t editor_style_set(int32_t handle, int32_t tool, int32_t property, double value);
void editor_style_dispose(int32_t handle);

#ifdef __cplusplus
}
#endif
#endif
