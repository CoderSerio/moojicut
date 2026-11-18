#include "canvas.h"
#include <string.h>

static MCCanvasRect command_rect(int32_t frame, int32_t layer, int32_t index) {
  return (MCCanvasRect){
    ui_frame_command_number(frame, layer, index, MC_UI_DRAW_X),
    ui_frame_command_number(frame, layer, index, MC_UI_DRAW_Y),
    ui_frame_command_number(frame, layer, index, MC_UI_DRAW_WIDTH),
    ui_frame_command_number(frame, layer, index, MC_UI_DRAW_HEIGHT)
  };
}

bool mc_canvas_draw_layer(int32_t frame, int32_t layer, const MCCanvasPainter *painter) {
  if (!painter || !painter->rectangle || !painter->line || !painter->text) return false;
  int32_t count = ui_frame_command_count(frame, layer);
  if (count < 0) return false;
  for (int32_t index = 0; index < count; index++) {
    int32_t kind = ui_frame_command_value(frame, layer, index, MC_UI_DRAW_TYPE);
    if (kind == MC_UI_COMMAND_RECT) {
      painter->rectangle(painter->context, command_rect(frame, layer, index),
        ui_frame_command_number(frame, layer, index, MC_UI_DRAW_RADIUS),
        ui_frame_command_value(frame, layer, index, MC_UI_DRAW_FILL),
        ui_frame_command_value(frame, layer, index, MC_UI_DRAW_STROKE),
        ui_frame_command_number(frame, layer, index, MC_UI_DRAW_LINE_WIDTH));
    } else if (kind == MC_UI_COMMAND_LINE) {
      painter->line(painter->context,
        ui_frame_command_number(frame, layer, index, MC_UI_DRAW_X),
        ui_frame_command_number(frame, layer, index, MC_UI_DRAW_Y),
        ui_frame_command_number(frame, layer, index, MC_UI_DRAW_X2),
        ui_frame_command_number(frame, layer, index, MC_UI_DRAW_Y2),
        ui_frame_command_value(frame, layer, index, MC_UI_DRAW_COLOR),
        ui_frame_command_number(frame, layer, index, MC_UI_DRAW_LINE_WIDTH));
    } else if (kind == MC_UI_COMMAND_TEXT) {
      moonbit_string_t value = ui_frame_command_text(frame, layer, index);
      MCCanvasText text = {
        command_rect(frame, layer, index), (const uint16_t *)value,
        (size_t)Moonbit_array_length(value),
        ui_frame_command_value(frame, layer, index, MC_UI_DRAW_COLOR),
        ui_frame_command_value(frame, layer, index, MC_UI_DRAW_WEIGHT),
        ui_frame_command_value(frame, layer, index, MC_UI_DRAW_ALIGN),
        ui_frame_command_value(frame, layer, index, MC_UI_DRAW_VALIGN),
        ui_frame_command_number(frame, layer, index, MC_UI_DRAW_FONT_SIZE)
      };
      painter->text(painter->context, &text);
      moonbit_decref(value);
    } else {
      // Only possible after illegal reentrant closure of the immutable frame.
      return false;
    }
  }
  return true;
}

bool mc_canvas_video_rect(int32_t frame, MCCanvasRect *rect) {
  if (!rect || ui_frame_value(frame, MC_UI_FRAME_HAS_VIDEO) != 1) return false;
  *rect = (MCCanvasRect){ui_frame_video_rect(frame, MC_UI_RECT_X),
    ui_frame_video_rect(frame, MC_UI_RECT_Y),
    ui_frame_video_rect(frame, MC_UI_RECT_WIDTH),
    ui_frame_video_rect(frame, MC_UI_RECT_HEIGHT)};
  return true;
}

moonbit_string_t mc_canvas_input_json(const MCCanvasInput *input) {
  if (!input || input->text_length > 256 ||
      (input->text_length && !input->text)) return moonbit_make_string_raw(0);
  moonbit_string_t text = moonbit_make_string_raw((int32_t)input->text_length);
  if (input->text_length) memcpy(text, input->text, input->text_length * sizeof(uint16_t));
  moonbit_string_t result = ui_input_event(input->type, input->x, input->y,
    input->delta_x, input->delta_y, input->flags, text);
  moonbit_decref(text);
  return result;
}

moonbit_string_t mc_canvas_text_input_json(const MCCanvasTextInput *input) {
  if (!input || !input->id_length || input->id_length > 256 || !input->id ||
      input->text_length > 32768 || (input->text_length && !input->text))
    return moonbit_make_string_raw(0);
  moonbit_string_t id = moonbit_make_string_raw((int32_t)input->id_length);
  moonbit_string_t text = moonbit_make_string_raw((int32_t)input->text_length);
  memcpy(id, input->id, input->id_length * sizeof(uint16_t));
  if (input->text_length) memcpy(text, input->text, input->text_length * sizeof(uint16_t));
  moonbit_string_t result = ui_text_event(input->type, id, input->token, input->version,
      input->start, input->end, text, input->selection_kind, input->anchor, input->focus);
  moonbit_decref(id);
  moonbit_decref(text);
  return result;
}
