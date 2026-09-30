// morph_rs.h — C interface to Morph's Rust image codecs (see src/lib.rs).
// Buffers returned in MorphBuffer must be released with morph_buffer_free().
#ifndef MORPH_RS_H
#define MORPH_RS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MORPH_OK 0
#define MORPH_ERR_INVALID_ARGUMENT 1
#define MORPH_ERR_PARSE 2
#define MORPH_ERR_ENCODE 3
#define MORPH_ERR_QUALITY_TOO_LOW 4
#define MORPH_ERR_TOO_LARGE 5
#define MORPH_ERR_PANIC 99

typedef struct MorphBuffer {
    uint8_t *ptr;
    size_t len;
    size_t cap;
} MorphBuffer;

typedef struct MorphPNGOptions {
    uint8_t quality_min;      // 0-100; below it -> MORPH_ERR_QUALITY_TOO_LOW
    uint8_t quality_max;      // 0-100 target
    float dithering;          // 0.0-1.0
    int32_t speed;            // 1 (best) - 10 (fastest)
    uint8_t optimization;     // oxipng preset 0-6
    bool zopfli;              // slower, slightly smaller
    bool premultiplied;       // input pixels are premultiplied
    const uint8_t *icc;       // optional ICC profile
    size_t icc_len;
    uint32_t timeout_ms;      // 0 = no limit
} MorphPNGOptions;

typedef struct MorphTraceOptions {
    bool color;               // color vs black & white
    bool stacked;             // stacked vs cutout shapes
    uint32_t filter_speckle;  // default 4
    int32_t color_precision;  // 1-8, default 6
    int32_t layer_difference; // default 16
    uint8_t mode;             // 0 pixel, 1 polygon, 2 spline
    int32_t corner_threshold; // degrees, default 60
    double length_threshold;  // 3.5-10, default 4.0
    uint32_t max_iterations;  // default 10
    int32_t splice_threshold; // degrees, default 45
    uint32_t path_precision;  // decimals, default 2
    bool premultiplied;       // input pixels are premultiplied
} MorphTraceOptions;

const char *morph_version(void);
const char *morph_last_error(void);
void morph_buffer_free(MorphBuffer buffer);

// SVG (resvg). Output pixels are premultiplied RGBA8, tightly packed.
int32_t morph_svg_size(const uint8_t *data, size_t len, float *out_width, float *out_height);
void morph_svg_warm_up(void);
int32_t morph_svg_render(const uint8_t *data, size_t len, uint32_t width, uint32_t height,
                         MorphBuffer *out_rgba, uint32_t *out_width, uint32_t *out_height);

// PNG (quantizr + oxipng). Input pixels are RGBA8, tightly packed.
int32_t morph_png_quantize(const uint8_t *rgba, uint32_t width, uint32_t height,
                           const MorphPNGOptions *options, MorphBuffer *out_png);
int32_t morph_png_optimize(const uint8_t *png, size_t len, uint8_t level, bool zopfli,
                           bool strip_metadata, uint32_t timeout_ms, MorphBuffer *out_png);

// Raster -> SVG (vtracer). Output is UTF-8 SVG text (not NUL-terminated).
int32_t morph_trace_svg(const uint8_t *rgba, uint32_t width, uint32_t height,
                        const MorphTraceOptions *options, MorphBuffer *out_svg);

#ifdef __cplusplus
}
#endif

#endif // MORPH_RS_H
