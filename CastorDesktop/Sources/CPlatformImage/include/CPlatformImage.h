#ifndef CASTOR_PLATFORM_IMAGE_H
#define CASTOR_PLATFORM_IMAGE_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Additional native image formats; decoded pixels are straight RGBA, top-left. */
int castor_image_info(const uint8_t *data, size_t length, int32_t *width, int32_t *height);
int castor_image_decode(const uint8_t *data, size_t length, uint8_t *rgba, int32_t width, int32_t height);
#ifdef __cplusplus
}
#endif
#endif
