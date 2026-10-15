#ifndef CASTOR_ONNX_H
#define CASTOR_ONNX_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// ONNX Runtime loaded at run time from `library_path` (onnxruntime.dll /
/// libonnxruntime.dylib), so Castor builds and runs without it and only the
/// optional model download needs it. Returns 1 on success.
int castor_onnx_load(const char *library_path, char *error, size_t error_capacity);

typedef struct castor_onnx_session castor_onnx_session;

/// Opens a model file (UTF-8 path). NULL on failure, with `error` filled.
castor_onnx_session *castor_onnx_open(const char *model_path, int threads, char *error, size_t error_capacity);
void castor_onnx_close(castor_onnx_session *session);

/// Runs one float32 input and returns `output_count` float32 outputs. Each
/// `outputs[i]` is malloc'd (free with castor_onnx_free); `output_shapes`
/// holds 8 dimensions per output and `output_ranks` the used count.
/// Returns 1 on success.
int castor_onnx_run(castor_onnx_session *session,
                    const char *input_name, const int64_t *input_shape, size_t input_rank, const float *input,
                    const char *const *output_names, size_t output_count,
                    float **outputs, int64_t *output_shapes, size_t *output_ranks,
                    char *error, size_t error_capacity);

void castor_onnx_free(void *pointer);

#ifdef __cplusplus
}
#endif

#endif
