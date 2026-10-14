#ifndef CASTOR_DESKTOP_UI_H
#define CASTOR_DESKTOP_UI_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
/* UTF-8 paths. Returns 1 for OK, 0 for user cancellation, -1 for API failure. */
int castor_choose_file(int save, const char *kind, char *output, size_t capacity);
/* Four image-space rectangles (head, left eye, right eye, mouth), x/y/w/h each. */
int castor_review_markers(const uint8_t *rgba, int width, int height, float *rectangles);
/* Returns option index+1, 0 for cancellation, -1 for error. */
int castor_choose_option(const char *title, const char *options);
/* Pumps native UI while the locked host completion callback returns 0. */
int castor_wait_work(const char *text, int (*poll)(void *), void *context);
/* 0 cancel, 1 save, 2 save and open X; premultiplied BGRA preview frames. */
int castor_preview_gif(const uint8_t *frames, int count, int width, int height, int fps);
int castor_open_url(const char *url);
int castor_edit_text(const char *title, const char *initial, int readonly, char *output, size_t capacity);
void castor_update_work_text(const char *text);
int castor_system_voices(char *output, size_t capacity);
int castor_system_recognizers(char *output, size_t capacity);
int castor_system_speak(const char *text, const char *tokenId, int (*cancelled)(void *), void *context);
int castor_system_recognize(char *output, size_t capacity, int (*cancelled)(void *), void *context);
#ifdef __cplusplus
}
#endif
#endif
