/*
 * Debug-only frame-capture and head-pose diagnostic for the VITURE Luma Ultra
 * Carina C SDK (libglasses.so).
 *
 * The SDK is proprietary and not vendored, so every entry point is resolved
 * with dlopen at runtime. A capture:
 *   1. creates the device provider over an already-open Android USB fd,
 *   2. registers the Carina stereo camera callback,
 *   3. walks the fixed exposure ladder (0.1, 0.3, 1.0, 3.0 ms) at one gain,
 *   4. polls xr_device_provider_get_gl_pose_carina on its own thread,
 *   5. copies left0/right0/left1/right1 inside the callback, and
 *   6. writes one PGM per buffer per rung plus a JSON telemetry file.
 *
 * The only caller is the debug-only Dart FFI trigger; nothing here is built
 * into a release path. See the package README for the local libglasses.so
 * staging step.
 */

#include <android/log.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define LOG_TAG "WmrCarinaDiag"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

#define WMR_CARINA_OK 0
#define WMR_CARINA_ERR_ARGUMENT -1
#define WMR_CARINA_ERR_BUSY -2
#define WMR_CARINA_ERR_OUTPUT -3
#define WMR_CARINA_ERR_SDK_UNAVAILABLE -4
#define WMR_CARINA_ERR_SYMBOL -5
#define WMR_CARINA_ERR_CREATE -6
#define WMR_CARINA_ERR_INITIALIZE -7
#define WMR_CARINA_ERR_START -8
#define WMR_CARINA_ERR_CALLBACKS -9
#define WMR_CARINA_ERR_NO_FRAMES -10

#define WMR_CARINA_MAX_RUNGS 8
#define WMR_CARINA_MAX_DIMENSION 8192
#define WMR_CARINA_TELEMETRY_FILE "carina-diagnostics.json"
#define WMR_CARINA_POLL_INTERVAL_MS 10

/* Minimal ABI mirror of viture_device_carina.h and the provider lifecycle.
 * The vendor headers are not copied into this repository. */
typedef void (*CarinaPoseCallback)(float* pose, double timestamp);
typedef void (*CarinaVsyncCallback)(double timestamp);
typedef void (*CarinaImuCallback)(float* imu, double timestamp);
typedef void (*CarinaCameraCallback)(char* image_left0,
                                     char* image_right0,
                                     char* image_left1,
                                     char* image_right1,
                                     double timestamp,
                                     int width,
                                     int height);

typedef struct {
    void* (*create)(int product_id, int file_descriptor);
    int (*set_dof_type)(void* handle, int is_6dof);
    int (*register_callbacks)(void* handle,
                              CarinaPoseCallback pose_callback,
                              CarinaVsyncCallback vsync_callback,
                              CarinaImuCallback imu_callback,
                              CarinaCameraCallback camera_callback);
    int (*initialize)(void* handle, const char* custom_config, const char* cache_file_dir);
    int (*start)(void* handle);
    int (*stop)(void* handle);
    int (*shutdown)(void* handle);
    void (*destroy)(void* handle);
    int (*set_manual_exposure)(void* handle, float exposure_time_ms, int exposure_gain);
    int (*get_gl_pose)(void* handle, float* pose, double predict_time, int* pose_status);
} CarinaApi;

typedef struct {
    int width;
    int height;
    unsigned char* left0;
    unsigned char* right0;
    unsigned char* left1;
    unsigned char* right1;
} CarinaRungFrame;

typedef struct {
    pthread_mutex_t lock;
    atomic_int current_rung;
    atomic_int accepting;
    atomic_int callback_active;
    CarinaRungFrame frames[WMR_CARINA_MAX_RUNGS];
    int width;
    int height;
    uint64_t total_frames;
    uint64_t rung_frames[WMR_CARINA_MAX_RUNGS];
    uint64_t copy_samples;
    uint64_t copy_us_sum;
    uint64_t copy_us_max;
    double first_timestamp;
    double last_timestamp;
} CarinaCameraState;

typedef struct {
    float pose[7];
    int status;
    int valid;
} CarinaPoseSample;

static CarinaCameraState* g_camera = NULL;
static atomic_int g_running = 0;

static uint64_t monotonic_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000ull + (uint64_t)ts.tv_nsec / 1000ull;
}

static double monotonic_ms(void) {
    return (double)monotonic_us() / 1000.0;
}

static void sleep_ms(int milliseconds) {
    struct timespec request;
    request.tv_sec = milliseconds / 1000;
    request.tv_nsec = (long)(milliseconds % 1000) * 1000000L;
    nanosleep(&request, NULL);
}

static void free_rung(CarinaRungFrame* frame) {
    free(frame->left0);
    free(frame->right0);
    free(frame->left1);
    free(frame->right1);
    memset(frame, 0, sizeof(*frame));
}

static int allocate_rung(CarinaRungFrame* frame, int width, int height) {
    size_t bytes = (size_t)width * (size_t)height;
    free_rung(frame);
    frame->left0 = calloc(bytes, 1);
    frame->right0 = calloc(bytes, 1);
    frame->left1 = calloc(bytes, 1);
    frame->right1 = calloc(bytes, 1);
    if (frame->left0 == NULL || frame->right0 == NULL || frame->left1 == NULL ||
        frame->right1 == NULL) {
        free_rung(frame);
        return -1;
    }
    frame->width = width;
    frame->height = height;
    return 0;
}

static void on_camera(char* left0,
                      char* right0,
                      char* left1,
                      char* right1,
                      double timestamp,
                      int width,
                      int height) {
    CarinaCameraState* state = g_camera;
    if (state == NULL || !atomic_load(&state->accepting)) return;
    atomic_fetch_add(&state->callback_active, 1);

    if (left0 == NULL || right0 == NULL || left1 == NULL || right1 == NULL) {
        atomic_fetch_sub(&state->callback_active, 1);
        return;
    }
    if (width <= 0 || height <= 0 || width > WMR_CARINA_MAX_DIMENSION ||
        height > WMR_CARINA_MAX_DIMENSION) {
        atomic_fetch_sub(&state->callback_active, 1);
        return;
    }

    int rung = atomic_load(&state->current_rung);
    if (rung < 0 || rung >= WMR_CARINA_MAX_RUNGS) rung = 0;

    uint64_t copy_started = monotonic_us();
    pthread_mutex_lock(&state->lock);
    CarinaRungFrame* frame = &state->frames[rung];
    if (frame->width != width || frame->height != height) {
        if (allocate_rung(frame, width, height) != 0) {
            pthread_mutex_unlock(&state->lock);
            atomic_fetch_sub(&state->callback_active, 1);
            LOGE("frame buffer allocation failed for %dx%d", width, height);
            return;
        }
    }
    size_t bytes = (size_t)width * (size_t)height;
    memcpy(frame->left0, left0, bytes);
    memcpy(frame->right0, right0, bytes);
    memcpy(frame->left1, left1, bytes);
    memcpy(frame->right1, right1, bytes);

    if (state->width == 0) {
        state->width = width;
        state->height = height;
    }
    if (state->total_frames == 0) state->first_timestamp = timestamp;
    state->last_timestamp = timestamp;
    state->total_frames++;
    state->rung_frames[rung]++;
    pthread_mutex_unlock(&state->lock);

    uint64_t elapsed = monotonic_us() - copy_started;
    pthread_mutex_lock(&state->lock);
    state->copy_samples++;
    state->copy_us_sum += elapsed;
    if (elapsed > state->copy_us_max) state->copy_us_max = elapsed;
    pthread_mutex_unlock(&state->lock);

    atomic_fetch_sub(&state->callback_active, 1);
}

static void* resolve_symbol(void* library, const char* name) {
    void* symbol = dlsym(library, name);
    if (symbol == NULL) LOGE("missing SDK symbol %s", name);
    return symbol;
}

static int resolve_api(void* library, CarinaApi* api) {
    api->create = (void* (*)(int, int))resolve_symbol(library, "xr_device_provider_create");
    api->set_dof_type = (int (*)(void*, int))resolve_symbol(library,
                                                             "xr_device_provider_set_dof_type_carina");
    api->register_callbacks =
        (int (*)(void*, CarinaPoseCallback, CarinaVsyncCallback, CarinaImuCallback,
                 CarinaCameraCallback))resolve_symbol(library,
                                                      "xr_device_provider_register_callbacks_carina");
    api->initialize = (int (*)(void*, const char*, const char*))resolve_symbol(
        library, "xr_device_provider_initialize");
    api->start = (int (*)(void*))resolve_symbol(library, "xr_device_provider_start");
    api->stop = (int (*)(void*))resolve_symbol(library, "xr_device_provider_stop");
    api->shutdown = (int (*)(void*))resolve_symbol(library, "xr_device_provider_shutdown");
    api->destroy = (void (*)(void*))resolve_symbol(library, "xr_device_provider_destroy");
    api->set_manual_exposure = (int (*)(void*, float, int))resolve_symbol(
        library, "xr_device_provider_set_manual_exposure_carina");
    api->get_gl_pose = (int (*)(void*, float*, double, int*))resolve_symbol(
        library, "xr_device_provider_get_gl_pose_carina");
    return api->create != NULL && api->set_dof_type != NULL &&
                   api->register_callbacks != NULL && api->initialize != NULL &&
                   api->start != NULL && api->stop != NULL && api->shutdown != NULL &&
                   api->destroy != NULL && api->set_manual_exposure != NULL &&
                   api->get_gl_pose != NULL
               ? 0
               : -1;
}

static int open_library(void** library) {
    *library = dlopen("libglasses.so", RTLD_NOW | RTLD_LOCAL);
    if (*library != NULL) return 0;
    const char* override_path = getenv("WMR_CARINA_LIBGLASSES");
    if (override_path != NULL && override_path[0] != '\0') {
        *library = dlopen(override_path, RTLD_NOW | RTLD_LOCAL);
    }
    return *library != NULL ? 0 : -1;
}

static int write_pgm(const char* output_dir,
                     const char* name,
                     const unsigned char* data,
                     int width,
                     int height) {
    char path[1024];
    int length = snprintf(path, sizeof(path), "%s/%s", output_dir, name);
    if (length < 0 || (size_t)length >= sizeof(path) || data == NULL) return -1;
    FILE* file = fopen(path, "wb");
    if (file == NULL) return -1;
    fprintf(file, "P5\n%d %d\n255\n", width, height);
    size_t written = fwrite(data, 1, (size_t)width * (size_t)height, file);
    int close_result = fclose(file);
    return written == (size_t)width * (size_t)height && close_result == 0 ? 0 : -1;
}

static void json_string(char* out, size_t capacity, const char* value) {
    if (value == NULL) {
        snprintf(out, capacity, "null");
        return;
    }
    size_t cursor = 0;
    if (capacity > 1) out[cursor++] = '"';
    for (const char* character = value; *character != '\0' && cursor + 2 < capacity;
         character++) {
        unsigned char byte = (unsigned char)*character;
        if (byte == '"' || byte == '\\') {
            out[cursor++] = '\\';
            out[cursor++] = (char)byte;
        } else if (byte < 0x20) {
            out[cursor++] = ' ';
        } else {
            out[cursor++] = (char)byte;
        }
    }
    if (cursor < capacity) out[cursor++] = '"';
    out[cursor < capacity ? cursor : capacity - 1] = '\0';
}

static int write_failure(const char* output_dir, int code, const char* message) {
    char path[1024];
    int length =
        snprintf(path, sizeof(path), "%s/%s", output_dir, WMR_CARINA_TELEMETRY_FILE);
    if (length < 0 || (size_t)length >= sizeof(path)) return code;
    FILE* file = fopen(path, "wb");
    if (file == NULL) return code;
    fprintf(file,
            "{\"schema\":\"wmr.carina.diagnostics.v1\",\"ok\":false,"
            "\"code\":%d,\"error\":\"%s\"}\n",
            code, message != NULL ? message : "unknown error");
    fclose(file);
    return code;
}

/*
 * Blocking capture. Must run off the Android main thread. Returns 0 on success
 * and writes carina-diagnostics.json in output_directory on every path.
 */
__attribute__((visibility("default"))) int32_t wmr_carina_diag_capture(
    int32_t file_descriptor,
    int32_t product_id,
    const char* output_directory,
    const float* exposure_ladder_ms,
    int32_t ladder_length,
    int32_t gain,
    int32_t duration_ms) {
    if (file_descriptor < 0 || output_directory == NULL || output_directory[0] == '\0') {
        return WMR_CARINA_ERR_ARGUMENT;
    }
    if (exposure_ladder_ms == NULL || ladder_length < 1 ||
        ladder_length > WMR_CARINA_MAX_RUNGS) {
        return WMR_CARINA_ERR_ARGUMENT;
    }
    if (gain < 0) gain = 0;
    if (gain > 15) gain = 15;
    if (duration_ms < 500) duration_ms = 500;
    if (duration_ms > 60000) duration_ms = 60000;
    if (atomic_exchange(&g_running, 1)) return WMR_CARINA_ERR_BUSY;

    mkdir(output_directory, 0700);

    int result = WMR_CARINA_OK;
    const char* error = NULL;
    void* library = NULL;
    CarinaApi api;
    memset(&api, 0, sizeof(api));
    void* handle = NULL;
    int initialized = 0;
    int started = 0;
    int exposure_calls = 0;
    int exposure_failures = 0;
    int applied_rung = -1;
    CarinaPoseSample pose;
    memset(&pose, 0, sizeof(pose));
    uint64_t pose_polls = 0;
    uint64_t pose_successes = 0;
    int frame_files_written = 0;
    int frame_files_failed = 0;

    CarinaCameraState* state = calloc(1, sizeof(*state));
    if (state == NULL) {
        atomic_store(&g_running, 0);
        return write_failure(output_directory, WMR_CARINA_ERR_OUTPUT,
                             "cannot allocate capture state");
    }
    pthread_mutex_init(&state->lock, NULL);
    atomic_store(&state->current_rung, 0);

    if (open_library(&library) != 0) {
        result = WMR_CARINA_ERR_SDK_UNAVAILABLE;
        error = "libglasses.so is not loaded and was not found";
        goto done;
    }
    if (resolve_api(library, &api) != 0) {
        result = WMR_CARINA_ERR_SYMBOL;
        error = "libglasses.so is missing a required Carina symbol";
        goto done;
    }

    handle = api.create(product_id, file_descriptor);
    if (handle == NULL) {
        result = WMR_CARINA_ERR_CREATE;
        error = "xr_device_provider_create returned null";
        goto done;
    }
    /* Must run after create and before initialize (viture_device_carina.h). */
    if (api.set_dof_type(handle, 1) != 0) {
        result = WMR_CARINA_ERR_INITIALIZE;
        error = "xr_device_provider_set_dof_type_carina failed";
        goto done;
    }

    if (api.initialize(handle, NULL, output_directory) != 0) {
        result = WMR_CARINA_ERR_INITIALIZE;
        error = "xr_device_provider_initialize failed";
        goto done;
    }
    initialized = 1;
    if (api.start(handle) != 0) {
        result = WMR_CARINA_ERR_START;
        error = "xr_device_provider_start failed";
        goto done;
    }
    started = 1;

    g_camera = state;
    atomic_store(&state->accepting, 1);
    if (api.register_callbacks(handle, NULL, NULL, NULL, on_camera) != 0) {
        result = WMR_CARINA_ERR_CALLBACKS;
        error = "xr_device_provider_register_callbacks_carina failed";
        goto done;
    }

    exposure_calls++;
    if (api.set_manual_exposure(handle, exposure_ladder_ms[0], gain) != 0) {
        exposure_failures++;
    }
    applied_rung = 0;
    atomic_store(&state->current_rung, 0);

    double capture_started = monotonic_ms();
    while ((monotonic_ms() - capture_started) < (double)duration_ms) {
        double elapsed = monotonic_ms() - capture_started;
        int rung = (int)((elapsed * (double)ladder_length) / (double)duration_ms);
        if (rung < 0) rung = 0;
        if (rung >= ladder_length) rung = ladder_length - 1;
        if (rung != applied_rung) {
            exposure_calls++;
            if (api.set_manual_exposure(handle, exposure_ladder_ms[rung], gain) != 0) {
                exposure_failures++;
            }
            applied_rung = rung;
            atomic_store(&state->current_rung, rung);
        }

        float sample[7];
        int status = -1;
        int pose_result = api.get_gl_pose(handle, sample, 0.0, &status);
        pose_polls++;
        if (pose_result == 0) {
            pose_successes++;
            memcpy(pose.pose, sample, sizeof(pose.pose));
            pose.status = status;
            pose.valid = 1;
        }
        sleep_ms(WMR_CARINA_POLL_INTERVAL_MS);
    }

done:
    /* Stop accepting before stop() so no new callback can pass the gate. */
    atomic_store(&state->accepting, 0);
    if (handle != NULL && started) api.stop(handle);
    if (handle != NULL && initialized) api.shutdown(handle);
    if (handle != NULL) api.destroy(handle);
    /* A callback that passed the gate may still be mid-copy; one frame period
     * at 25 Hz plus a short drain is enough before reading its buffers. */
    sleep_ms(100);
    for (int waits = 0; waits < 1000 && atomic_load(&state->callback_active) > 0; waits++) {
        sleep_ms(1);
    }
    g_camera = NULL;

    pthread_mutex_lock(&state->lock);
    uint64_t frames = state->total_frames;
    int width = state->width;
    int height = state->height;
    uint64_t copy_samples = state->copy_samples;
    uint64_t copy_sum = state->copy_us_sum;
    uint64_t copy_max = state->copy_us_max;
    double first_timestamp = state->first_timestamp;
    double last_timestamp = state->last_timestamp;
    uint64_t rung_frames[WMR_CARINA_MAX_RUNGS];
    memcpy(rung_frames, state->rung_frames, sizeof(rung_frames));
    pthread_mutex_unlock(&state->lock);

    if (result == WMR_CARINA_OK && frames == 0) {
        result = WMR_CARINA_ERR_NO_FRAMES;
        error = "no Carina camera frames arrived";
    }

    if (result == WMR_CARINA_OK) {
        for (int rung = 0; rung < ladder_length; rung++) {
            CarinaRungFrame* frame = &state->frames[rung];
            if (frame->width == 0 || frame->height == 0) continue;
            const char* channels[4] = {"left0", "right0", "left1", "right1"};
            unsigned char* buffers[4] = {frame->left0, frame->right0, frame->left1,
                                         frame->right1};
            for (int channel = 0; channel < 4; channel++) {
                char name[128];
                snprintf(name, sizeof(name), "carina-rung%d-%s-%gms.pgm", rung,
                         channels[channel], (double)exposure_ladder_ms[rung]);
                if (write_pgm(output_directory, name, buffers[channel], frame->width,
                              frame->height) == 0) {
                    frame_files_written++;
                } else {
                    frame_files_failed++;
                }
            }
        }
        if (frame_files_written == 0) {
            result = WMR_CARINA_ERR_NO_FRAMES;
            error = "no Carina camera frames could be dumped";
        }
    }

    char path[1024];
    char error_json[512];
    json_string(error_json, sizeof(error_json), error);
    int telemetry_written = 0;
    int path_length =
        snprintf(path, sizeof(path), "%s/%s", output_directory, WMR_CARINA_TELEMETRY_FILE);
    if (path_length > 0 && (size_t)path_length < sizeof(path)) {
        FILE* file = fopen(path, "wb");
        if (file != NULL) {
            double fps = 0.0;
            if (frames > 1 && last_timestamp > first_timestamp) {
                fps = (double)(frames - 1) / (last_timestamp - first_timestamp);
            }
            fprintf(file,
                    "{\"schema\":\"wmr.carina.diagnostics.v1\",\"ok\":%s,"
                    "\"code\":%d,\"error\":%s,\"width\":%d,\"height\":%d,"
                    "\"frames\":%llu,\"fps\":%.3f,"
                    "\"callbackCopyLatencyUs\":{\"samples\":%llu,\"mean\":%.1f,"
                    "\"max\":%llu},"
                    "\"pose\":{\"polls\":%llu,\"successes\":%llu,\"rateHz\":%.3f,"
                    "\"status\":%d,\"valid\":%s,\"last\":[%.5f,%.5f,%.5f,%.5f,%.5f,"
                    "%.5f,%.5f]},"
                    "\"exposure\":{\"ladderMs\":[",
                    error == NULL ? "true" : "false", result, error_json, width, height,
                    (unsigned long long)frames, fps,
                    (unsigned long long)copy_samples,
                    copy_samples > 0 ? (double)copy_sum / (double)copy_samples : 0.0,
                    (unsigned long long)copy_max, (unsigned long long)pose_polls,
                    (unsigned long long)pose_successes,
                    duration_ms > 0 ? (double)pose_polls / ((double)duration_ms / 1000.0)
                                    : 0.0,
                    pose.status, pose.valid ? "true" : "false", (double)pose.pose[0],
                    (double)pose.pose[1], (double)pose.pose[2], (double)pose.pose[3],
                    (double)pose.pose[4], (double)pose.pose[5], (double)pose.pose[6]);
            for (int rung = 0; rung < ladder_length; rung++) {
                fprintf(file, "%s%g", rung == 0 ? "" : ",",
                        (double)exposure_ladder_ms[rung]);
            }
            fprintf(file, "],\"gain\":%d,\"calls\":%d,\"failures\":%d,\"framesPerRung\":[",
                    gain, exposure_calls, exposure_failures);
            for (int rung = 0; rung < ladder_length; rung++) {
                fprintf(file, "%s%llu", rung == 0 ? "" : ",",
                        (unsigned long long)rung_frames[rung]);
            }
            fprintf(file, "]},\"frameFilesWritten\":%d,\"frameFilesFailed\":%d,"
                          "\"durationMs\":%d}\n",
                    frame_files_written, frame_files_failed, duration_ms);
            telemetry_written = fclose(file) == 0;
        }
    }
    if (!telemetry_written) result = WMR_CARINA_ERR_OUTPUT;

    for (int rung = 0; rung < WMR_CARINA_MAX_RUNGS; rung++) {
        free_rung(&state->frames[rung]);
    }
    pthread_mutex_destroy(&state->lock);
    free(state);
    if (library != NULL) dlclose(library);
    if (result != WMR_CARINA_OK && error != NULL) {
        LOGI("capture failed (%d): %s", result, error);
    }
    atomic_store(&g_running, 0);
    if (result != WMR_CARINA_OK && !telemetry_written) {
        write_failure(output_directory, result, error);
    }
    return result;
}
