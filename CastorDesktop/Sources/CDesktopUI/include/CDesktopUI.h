#ifndef CASTOR_DESKTOP_UI_H
#define CASTOR_DESKTOP_UI_H
#include <stdint.h>
#include <stddef.h>
/* UTF-8 paths. Returns 1 for OK, 0 for user cancellation, -1 for API failure. */
int castor_choose_file(int save, const char *kind, char *output, size_t capacity);
/* Four image-space rectangles (head, left eye, right eye, mouth), x/y/w/h each. */
int castor_review_markers(const uint8_t *rgba, int width, int height, float *rectangles);
#endif
