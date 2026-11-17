#ifndef MOOJICUT_LINUX_VIDEO_EDITOR_H
#define MOOJICUT_LINUX_VIDEO_EDITOR_H
#include <gtk/gtk.h>
#include <stdint.h>
/* Thin window around the shared MoonBit editor owner. Paths are copied. The
 * application stays held until media/IO has drained, including failed saves.
 * Returned widget is borrowed. Use gtk_window_close (not gtk_widget_destroy)
 * to retain the window when saving fails and allow the user to retry. */
GtkWidget *mc_linux_video_editor_open(GtkApplication *application, const char *source, const char *draft);
GtkWidget *mc_linux_video_editor_open_test(GtkApplication *application, const char *source,
                                          const char *draft, gboolean silent);
gboolean mc_linux_video_editors_busy(void);
/* True iff all live windows still accept the requested close (also true when
 * none remain). busy && !closing lets the app withdraw quit after a save veto. */
gboolean mc_linux_video_editors_closing(void);
gboolean mc_linux_video_editors_close(void);
/* Same shared command endpoint used by the window, for automation/fixtures. */
gboolean mc_linux_video_editor_command(GtkWidget *window, const char *json);
char *mc_linux_video_editor_state(GtkWidget *window);
void mc_linux_video_editor_text_free(char *text);
/* Caller owns the immutable ui_frame; release with ui_frame_close. */
int32_t mc_linux_video_editor_frame_snapshot(GtkWidget *window);
#endif
