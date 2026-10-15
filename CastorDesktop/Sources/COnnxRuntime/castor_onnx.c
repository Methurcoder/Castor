// Thin C bridge over the ONNX Runtime C API (MIT, vendored headers in
// vendor/). The runtime library is loaded at run time, so nothing links
// against it: without the optional download Castor simply keeps its non-ML
// path.

#include "castor_onnx.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <dlfcn.h>
#endif

#include "../vendor/onnxruntime_c_api.h"

static const OrtApi *api = NULL;
static OrtEnv *env = NULL;

struct castor_onnx_session {
    OrtSession *session;
};

static void set_error(char *error, size_t capacity, const char *message) {
    if (error && capacity) {
        snprintf(error, capacity, "%s", message ? message : "unknown ONNX Runtime error");
    }
}

/// Copies the status message into `error`, releases it, and returns 0 (or 1 when there was no error).
static int check(OrtStatus *status, char *error, size_t capacity) {
    if (!status) return 1;
    set_error(error, capacity, api->GetErrorMessage(status));
    api->ReleaseStatus(status);
    return 0;
}

int castor_onnx_load(const char *library_path, char *error, size_t error_capacity) {
    if (api) return 1;
    typedef const OrtApiBase *(ORT_API_CALL *GetApiBase)(void);
    GetApiBase get_api_base = NULL;
#ifdef _WIN32
    int length = MultiByteToWideChar(CP_UTF8, 0, library_path, -1, NULL, 0);
    if (length <= 0) { set_error(error, error_capacity, "invalid runtime path"); return 0; }
    wchar_t *wide = (wchar_t *)malloc(sizeof(wchar_t) * (size_t)length);
    if (!wide) { set_error(error, error_capacity, "out of memory"); return 0; }
    MultiByteToWideChar(CP_UTF8, 0, library_path, -1, wide, length);
    // Search the runtime's own folder for its dependencies, never the
    // current directory.
    HMODULE module = LoadLibraryExW(wide, NULL, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    free(wide);
    if (!module) { set_error(error, error_capacity, "could not load the ONNX Runtime library"); return 0; }
    get_api_base = (GetApiBase)(void *)GetProcAddress(module, "OrtGetApiBase");
#else
    void *module = dlopen(library_path, RTLD_NOW | RTLD_LOCAL);
    if (!module) { set_error(error, error_capacity, dlerror()); return 0; }
    get_api_base = (GetApiBase)dlsym(module, "OrtGetApiBase");
#endif
    if (!get_api_base) { set_error(error, error_capacity, "OrtGetApiBase not found"); return 0; }
    const OrtApi *loaded = get_api_base()->GetApi(ORT_API_VERSION);
    if (!loaded) { set_error(error, error_capacity, "this ONNX Runtime is older than the headers Castor was built with"); return 0; }
    api = loaded;
    if (!check(api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "Castor", &env), error, error_capacity)) {
        api = NULL;
        return 0;
    }
    return 1;
}

castor_onnx_session *castor_onnx_open(const char *model_path, int threads, char *error, size_t error_capacity) {
    if (!api || !env) { set_error(error, error_capacity, "ONNX Runtime is not loaded"); return NULL; }
    OrtSessionOptions *options = NULL;
    if (!check(api->CreateSessionOptions(&options), error, error_capacity)) return NULL;
    int ok = 1;
    if (threads > 0) ok = check(api->SetIntraOpNumThreads(options, threads), error, error_capacity);
    if (ok) ok = check(api->SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL), error, error_capacity);
    OrtSession *session = NULL;
    if (ok) {
#ifdef _WIN32
        int length = MultiByteToWideChar(CP_UTF8, 0, model_path, -1, NULL, 0);
        wchar_t *wide = length > 0 ? (wchar_t *)malloc(sizeof(wchar_t) * (size_t)length) : NULL;
        if (wide) {
            MultiByteToWideChar(CP_UTF8, 0, model_path, -1, wide, length);
            ok = check(api->CreateSession(env, wide, options, &session), error, error_capacity);
            free(wide);
        } else {
            set_error(error, error_capacity, "invalid model path");
            ok = 0;
        }
#else
        ok = check(api->CreateSession(env, model_path, options, &session), error, error_capacity);
#endif
    }
    api->ReleaseSessionOptions(options);
    if (!ok) return NULL;
    castor_onnx_session *result = (castor_onnx_session *)calloc(1, sizeof(castor_onnx_session));
    if (!result) { api->ReleaseSession(session); set_error(error, error_capacity, "out of memory"); return NULL; }
    result->session = session;
    return result;
}

void castor_onnx_close(castor_onnx_session *session) {
    if (!session) return;
    if (api && session->session) api->ReleaseSession(session->session);
    free(session);
}

int castor_onnx_run(castor_onnx_session *session,
                    const char *input_name, const int64_t *input_shape, size_t input_rank, const float *input,
                    const char *const *output_names, size_t output_count,
                    float **outputs, int64_t *output_shapes, size_t *output_ranks,
                    char *error, size_t error_capacity) {
    if (!api || !session) { set_error(error, error_capacity, "no session"); return 0; }
    for (size_t i = 0; i < output_count; i++) outputs[i] = NULL;

    size_t count = 1;
    for (size_t i = 0; i < input_rank; i++) count *= (size_t)input_shape[i];
    OrtMemoryInfo *memory = NULL;
    if (!check(api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memory), error, error_capacity)) return 0;
    OrtValue *tensor = NULL;
    int ok = check(api->CreateTensorWithDataAsOrtValue(memory, (void *)input, count * sizeof(float),
                                                      input_shape, input_rank,
                                                      ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &tensor),
                   error, error_capacity);
    api->ReleaseMemoryInfo(memory);
    if (!ok) return 0;

    OrtValue **results = (OrtValue **)calloc(output_count, sizeof(OrtValue *));
    if (!results) { api->ReleaseValue(tensor); set_error(error, error_capacity, "out of memory"); return 0; }
    const char *input_names[1] = {input_name};
    const OrtValue *inputs[1] = {tensor};
    ok = check(api->Run(session->session, NULL, input_names, inputs, 1, output_names, output_count, results),
               error, error_capacity);
    api->ReleaseValue(tensor);

    for (size_t i = 0; ok && i < output_count; i++) {
        OrtTensorTypeAndShapeInfo *info = NULL;
        ok = check(api->GetTensorTypeAndShape(results[i], &info), error, error_capacity);
        if (!ok) break;
        ONNXTensorElementDataType type = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED;
        size_t rank = 0, elements = 0;
        ok = check(api->GetTensorElementType(info, &type), error, error_capacity)
            && check(api->GetDimensionsCount(info, &rank), error, error_capacity)
            && check(api->GetTensorShapeElementCount(info, &elements), error, error_capacity);
        if (ok && (type != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT || rank > 8)) {
            set_error(error, error_capacity, "unexpected output type or rank");
            ok = 0;
        }
        if (ok) ok = check(api->GetDimensions(info, output_shapes + i * 8, rank), error, error_capacity);
        api->ReleaseTensorTypeAndShapeInfo(info);
        if (!ok) break;
        output_ranks[i] = rank;
        float *data = NULL;
        ok = check(api->GetTensorMutableData(results[i], (void **)&data), error, error_capacity);
        if (!ok) break;
        outputs[i] = (float *)malloc(elements ? elements * sizeof(float) : 1);
        if (!outputs[i]) { set_error(error, error_capacity, "out of memory"); ok = 0; break; }
        memcpy(outputs[i], data, elements * sizeof(float));
    }
    for (size_t i = 0; i < output_count; i++) {
        if (results[i]) api->ReleaseValue(results[i]);
        if (!ok && outputs[i]) { free(outputs[i]); outputs[i] = NULL; }
    }
    free(results);
    return ok;
}

void castor_onnx_free(void *pointer) { free(pointer); }
