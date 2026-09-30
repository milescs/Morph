//! morph-rs: native image codecs for Morph, exposed through a small C ABI.
//!
//! - SVG → RGBA rendering (resvg)
//! - RGBA → SVG vector tracing (vtracer)
//! - RGBA → palette PNG quantization (quantizr) and lossless PNG optimization (oxipng)
//!
//! Every exported function is wrapped in `catch_unwind` so a panic (e.g. a malformed
//! input tripping an internal assertion) is reported as `MORPH_ERR_PANIC` instead of
//! aborting the host app. Buffers returned to the caller must be released with
//! `morph_buffer_free`.

use std::cell::RefCell;
use std::ffi::{CString, c_char};
use std::num::NonZeroU64;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use resvg::{tiny_skia, usvg};

pub const MORPH_OK: i32 = 0;
pub const MORPH_ERR_INVALID_ARGUMENT: i32 = 1;
pub const MORPH_ERR_PARSE: i32 = 2;
pub const MORPH_ERR_ENCODE: i32 = 3;
pub const MORPH_ERR_QUALITY_TOO_LOW: i32 = 4;
pub const MORPH_ERR_TOO_LARGE: i32 = 5;
pub const MORPH_ERR_PANIC: i32 = 99;

/// Hard limits that keep a hostile input from requesting absurd allocations.
const MAX_SIDE: u32 = 32_768;
const MAX_PIXELS: u64 = 268_435_456; // 16384 x 16384

// ---------------------------------------------------------------------------
// Buffers & errors
// ---------------------------------------------------------------------------

#[repr(C)]
pub struct MorphBuffer {
    pub ptr: *mut u8,
    pub len: usize,
    pub cap: usize,
}

impl MorphBuffer {
    fn from_vec(mut v: Vec<u8>) -> Self {
        let buffer = MorphBuffer { ptr: v.as_mut_ptr(), len: v.len(), cap: v.capacity() };
        std::mem::forget(v);
        buffer
    }
}

struct MorphError {
    code: i32,
    message: String,
}

impl MorphError {
    fn new(code: i32, message: impl Into<String>) -> Self {
        MorphError { code, message: message.into() }
    }
}

type MorphResult<T> = Result<T, MorphError>;

thread_local! {
    static LAST_ERROR: RefCell<Option<CString>> = const { RefCell::new(None) };
}

fn set_last_error(message: &str) {
    let sanitized = message.replace('\0', " ");
    LAST_ERROR.with(|slot| *slot.borrow_mut() = CString::new(sanitized).ok());
}

fn guard<F: FnOnce() -> MorphResult<()>>(f: F) -> i32 {
    LAST_ERROR.with(|slot| *slot.borrow_mut() = None);
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(())) => MORPH_OK,
        Ok(Err(error)) => {
            set_last_error(&error.message);
            error.code
        }
        Err(payload) => {
            let message = payload
                .downcast_ref::<&str>()
                .map(|s| s.to_string())
                .or_else(|| payload.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "internal error".to_string());
            set_last_error(&format!("panic: {message}"));
            MORPH_ERR_PANIC
        }
    }
}

unsafe fn slice<'a>(ptr: *const u8, len: usize) -> MorphResult<&'a [u8]> {
    if ptr.is_null() || len == 0 {
        return Err(MorphError::new(MORPH_ERR_INVALID_ARGUMENT, "empty input"));
    }
    Ok(unsafe { std::slice::from_raw_parts(ptr, len) })
}

fn check_dimensions(width: u32, height: u32) -> MorphResult<()> {
    if width == 0 || height == 0 {
        return Err(MorphError::new(MORPH_ERR_INVALID_ARGUMENT, "zero-sized image"));
    }
    if width > MAX_SIDE || height > MAX_SIDE || (width as u64) * (height as u64) > MAX_PIXELS {
        return Err(MorphError::new(MORPH_ERR_TOO_LARGE, format!("image too large ({width}x{height})")));
    }
    Ok(())
}

/// Reads `width * height` RGBA pixels, un-premultiplying if requested.
unsafe fn read_rgba(
    rgba: *const u8,
    width: u32,
    height: u32,
    premultiplied: bool,
) -> MorphResult<Vec<[u8; 4]>> {
    check_dimensions(width, height)?;
    let count = (width as usize) * (height as usize);
    let bytes = unsafe { slice(rgba, count * 4)? };
    Ok(bytes
        .chunks_exact(4)
        .map(|p| {
            let a = p[3];
            if premultiplied && a != 0 && a != 255 {
                let un = |c: u8| (((c as u32) * 255 + (a as u32) / 2) / (a as u32)).min(255) as u8;
                [un(p[0]), un(p[1]), un(p[2]), a]
            } else if premultiplied && a == 0 {
                [0, 0, 0, 0]
            } else {
                [p[0], p[1], p[2], a]
            }
        })
        .collect())
}

/// Frees a buffer previously returned by this library. Safe to call with an empty buffer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn morph_buffer_free(buffer: MorphBuffer) {
    if !buffer.ptr.is_null() {
        drop(unsafe { Vec::from_raw_parts(buffer.ptr, buffer.len, buffer.cap) });
    }
}

/// The last error message produced on the calling thread, or NULL. Valid until the next call.
#[unsafe(no_mangle)]
pub extern "C" fn morph_last_error() -> *const c_char {
    LAST_ERROR.with(|slot| slot.borrow().as_ref().map_or(std::ptr::null(), |s| s.as_ptr()))
}

/// A static, NUL-terminated version string listing the bundled libraries.
#[unsafe(no_mangle)]
pub extern "C" fn morph_version() -> *const c_char {
    static VERSION: &str = concat!(
        "morph-rs ",
        env!("CARGO_PKG_VERSION"),
        " (resvg 0.48.1, vtracer 0.6.5, oxipng 10.2.1, quantizr 1.4.3)\0"
    );
    VERSION.as_ptr() as *const c_char
}

// ---------------------------------------------------------------------------
// SVG rendering (resvg)
// ---------------------------------------------------------------------------

fn system_fonts() -> Arc<usvg::fontdb::Database> {
    static FONTS: OnceLock<Arc<usvg::fontdb::Database>> = OnceLock::new();
    FONTS
        .get_or_init(|| {
            let mut db = usvg::fontdb::Database::new();
            db.load_system_fonts();
            db.set_serif_family("Times New Roman");
            db.set_sans_serif_family("Helvetica");
            db.set_cursive_family("Apple Chancery");
            db.set_fantasy_family("Papyrus");
            db.set_monospace_family("Menlo");
            Arc::new(db)
        })
        .clone()
}

fn svg_options(with_fonts: bool) -> usvg::Options<'static> {
    let mut options = usvg::Options::default();
    options.font_family = "Helvetica".to_string();
    if with_fonts {
        options.fontdb = system_fonts();
    }
    options
}

fn parse_svg(data: &[u8], with_fonts: bool) -> MorphResult<usvg::Tree> {
    usvg::Tree::from_data(data, &svg_options(with_fonts))
        .map_err(|e| MorphError::new(MORPH_ERR_PARSE, format!("invalid SVG: {e}")))
}

/// Reports the intrinsic size of an SVG document (in CSS pixels).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn morph_svg_size(
    data: *const u8,
    len: usize,
    out_width: *mut f32,
    out_height: *mut f32,
) -> i32 {
    guard(|| {
        let bytes = unsafe { slice(data, len)? };
        let tree = parse_svg(bytes, false)?;
        let size = tree.size();
        unsafe {
            if !out_width.is_null() {
                *out_width = size.width();
            }
            if !out_height.is_null() {
                *out_height = size.height();
            }
        }
        Ok(())
    })
}

/// Loads the system font database ahead of time (it is IO heavy on first use).
#[unsafe(no_mangle)]
pub extern "C" fn morph_svg_warm_up() {
    let _ = catch_unwind(|| {
        let _ = system_fonts();
    });
}

/// Renders an SVG document into a tightly packed, **premultiplied** RGBA8 buffer.
///
/// - `width == 0 && height == 0`: render at the intrinsic size.
/// - one of them 0: scale uniformly to the given side, keeping the aspect ratio.
/// - both set: scale uniformly to fit inside `width x height` (no letterboxing).
///
/// The rendered pixel size is written to `out_width` / `out_height`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn morph_svg_render(
    data: *const u8,
    len: usize,
    width: u32,
    height: u32,
    out_rgba: *mut MorphBuffer,
    out_width: *mut u32,
    out_height: *mut u32,
) -> i32 {
    guard(|| {
        if out_rgba.is_null() || out_width.is_null() || out_height.is_null() {
            return Err(MorphError::new(MORPH_ERR_INVALID_ARGUMENT, "null output pointer"));
        }
        let bytes = unsafe { slice(data, len)? };
        let tree = parse_svg(bytes, true)?;
        let size = tree.size();
        let (sw, sh) = (size.width().max(1.0), size.height().max(1.0));

        let scale = match (width, height) {
            (0, 0) => 1.0,
            (w, 0) => w as f32 / sw,
            (0, h) => h as f32 / sh,
            (w, h) => (w as f32 / sw).min(h as f32 / sh),
        };
        let pw = (sw * scale).round().max(1.0) as u32;
        let ph = (sh * scale).round().max(1.0) as u32;
        check_dimensions(pw, ph)?;

        let mut pixmap = tiny_skia::Pixmap::new(pw, ph)
            .ok_or_else(|| MorphError::new(MORPH_ERR_TOO_LARGE, "cannot allocate pixmap"))?;
        let transform = tiny_skia::Transform::from_scale(pw as f32 / sw, ph as f32 / sh);
        resvg::render(&tree, transform, &mut pixmap.as_mut());

        unsafe {
            *out_width = pw;
            *out_height = ph;
            *out_rgba = MorphBuffer::from_vec(pixmap.take());
        }
        Ok(())
    })
}

// ---------------------------------------------------------------------------
// PNG: quantization (quantizr) + optimization (oxipng)
// ---------------------------------------------------------------------------

#[repr(C)]
pub struct MorphPNGOptions {
    /// Unused (kept for ABI compatibility).
    pub quality_min: u8,
    /// Target quality 40–100 (mapped to the palette size).
    pub quality_max: u8,
    /// Dithering level 0.0 - 1.0.
    pub dithering: f32,
    /// Unused (kept for ABI compatibility).
    pub speed: i32,
    /// oxipng preset 0 - 6.
    pub optimization: u8,
    /// Use Zopfli for the final deflate (much slower, a few % smaller).
    pub zopfli: bool,
    /// Input pixels are premultiplied (as produced by CGBitmapContext).
    pub premultiplied: bool,
    /// Optional ICC profile to embed (may be NULL).
    pub icc: *const u8,
    pub icc_len: usize,
    /// Give up optimizing after this many milliseconds (0 = no limit).
    pub timeout_ms: u32,
}

fn oxipng_options(level: u8, zopfli: bool, timeout_ms: u32) -> oxipng::Options {
    let mut options = oxipng::Options::from_preset(level.min(6));
    if zopfli {
        let mut z = oxipng::ZopfliOptions::default();
        z.iteration_count = NonZeroU64::new(15).unwrap();
        options.deflater = oxipng::Deflater::Zopfli(z);
    }
    if timeout_ms > 0 {
        options.timeout = Some(Duration::from_millis(timeout_ms as u64));
    }
    options
}

/// Quantizes RGBA8 pixels to a ≤256-color palette (quantizr) and writes an optimized indexed PNG.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn morph_png_quantize(
    rgba: *const u8,
    width: u32,
    height: u32,
    options: *const MorphPNGOptions,
    out_png: *mut MorphBuffer,
) -> i32 {
    guard(|| {
        if options.is_null() || out_png.is_null() {
            return Err(MorphError::new(MORPH_ERR_INVALID_ARGUMENT, "null argument"));
        }
        let opts = unsafe { &*options };
        let pixels = unsafe { read_rgba(rgba, width, height, opts.premultiplied)? };

        // Map the 0–100 quality target to a palette size: 40 → 16 colors … 100 → 256 colors.
        let q = ((opts.quality_max.min(100) as f32 - 40.0) / 60.0).clamp(0.0, 1.0);
        let max_colors = (16.0 + 240.0 * q.powf(1.5)).round().clamp(2.0, 256.0) as i32;

        let flat: Vec<u8> = pixels.iter().flatten().copied().collect();
        let image = quantizr::Image::new(&flat, width as usize, height as usize)
            .map_err(|e| MorphError::new(MORPH_ERR_ENCODE, format!("quantization failed: {e:?}")))?;
        let mut options = quantizr::Options::default();
        options
            .set_max_colors(max_colors)
            .map_err(|e| MorphError::new(MORPH_ERR_ENCODE, format!("quantization failed: {e:?}")))?;
        let mut result = quantizr::QuantizeResult::quantize(&image, &options);
        result
            .set_dithering_level(opts.dithering.clamp(0.0, 1.0))
            .map_err(|e| MorphError::new(MORPH_ERR_ENCODE, format!("quantization failed: {e:?}")))?;
        let mut indices = vec![0u8; (width as usize) * (height as usize)];
        result
            .remap_image(&image, &mut indices)
            .map_err(|e| MorphError::new(MORPH_ERR_ENCODE, format!("quantization failed: {e:?}")))?;
        let quantized = result.get_palette();
        let palette_colors = &quantized.entries[..(quantized.count as usize).min(256)];

        let palette: Vec<oxipng::RGBA8> =
            palette_colors.iter().map(|c| oxipng::RGBA8::new(c.r, c.g, c.b, c.a)).collect();
        let mut raw = oxipng::RawImage::new(
            width,
            height,
            oxipng::ColorType::Indexed { palette },
            oxipng::BitDepth::Eight,
            indices,
        )
        .map_err(|e| MorphError::new(MORPH_ERR_ENCODE, format!("png: {e}")))?;
        if !opts.icc.is_null() && opts.icc_len > 0 {
            raw.add_icc_profile(unsafe { std::slice::from_raw_parts(opts.icc, opts.icc_len) });
        }
        let png = raw
            .create_optimized_png(&oxipng_options(opts.optimization, opts.zopfli, opts.timeout_ms))
            .map_err(|e| MorphError::new(MORPH_ERR_ENCODE, format!("png: {e}")))?;
        unsafe { *out_png = MorphBuffer::from_vec(png) };
        Ok(())
    })
}

/// Losslessly re-compresses an existing PNG (bit depth, color and metadata are preserved
/// unless `strip_metadata` is set, which removes chunks that don't affect display).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn morph_png_optimize(
    png: *const u8,
    len: usize,
    level: u8,
    zopfli: bool,
    strip_metadata: bool,
    timeout_ms: u32,
    out_png: *mut MorphBuffer,
) -> i32 {
    guard(|| {
        if out_png.is_null() {
            return Err(MorphError::new(MORPH_ERR_INVALID_ARGUMENT, "null output pointer"));
        }
        let bytes = unsafe { slice(png, len)? };
        let mut options = oxipng_options(level, zopfli, timeout_ms);
        if strip_metadata {
            options.strip = oxipng::StripChunks::Safe;
        }
        let optimized = oxipng::optimize_from_memory(bytes, &options)
            .map_err(|e| MorphError::new(MORPH_ERR_ENCODE, format!("png optimize: {e}")))?;
        unsafe { *out_png = MorphBuffer::from_vec(optimized) };
        Ok(())
    })
}

// ---------------------------------------------------------------------------
// Raster → SVG tracing (vtracer)
// ---------------------------------------------------------------------------

#[repr(C)]
pub struct MorphTraceOptions {
    /// true: color tracing, false: black & white.
    pub color: bool,
    /// true: stacked shapes (compact), false: cutout.
    pub stacked: bool,
    /// Discard patches smaller than N pixels (default 4).
    pub filter_speckle: u32,
    /// Significant bits per RGB channel, 1-8 (default 6).
    pub color_precision: i32,
    /// Color difference between gradient layers (default 16).
    pub layer_difference: i32,
    /// 0 = pixel, 1 = polygon, 2 = spline (default).
    pub mode: u8,
    /// Minimum momentary angle (degrees) to be considered a corner (default 60).
    pub corner_threshold: i32,
    /// Segment length threshold, 3.5-10 (default 4.0).
    pub length_threshold: f64,
    /// Maximum subdivide iterations (default 10).
    pub max_iterations: u32,
    /// Minimum angle displacement (degrees) to splice a spline (default 45).
    pub splice_threshold: i32,
    /// Decimal places in path coordinates (default 2).
    pub path_precision: u32,
    /// Input pixels are premultiplied.
    pub premultiplied: bool,
}

/// Traces RGBA8 pixels into an SVG document (UTF-8 bytes, not NUL-terminated).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn morph_trace_svg(
    rgba: *const u8,
    width: u32,
    height: u32,
    options: *const MorphTraceOptions,
    out_svg: *mut MorphBuffer,
) -> i32 {
    guard(|| {
        if options.is_null() || out_svg.is_null() {
            return Err(MorphError::new(MORPH_ERR_INVALID_ARGUMENT, "null argument"));
        }
        let opts = unsafe { &*options };
        let pixels = unsafe { read_rgba(rgba, width, height, opts.premultiplied)? };

        let image = vtracer::ColorImage {
            pixels: pixels.into_iter().flatten().collect(),
            width: width as usize,
            height: height as usize,
        };
        let config = vtracer::Config {
            color_mode: if opts.color { vtracer::ColorMode::Color } else { vtracer::ColorMode::Binary },
            hierarchical: if opts.stacked {
                vtracer::Hierarchical::Stacked
            } else {
                vtracer::Hierarchical::Cutout
            },
            filter_speckle: opts.filter_speckle as usize,
            color_precision: opts.color_precision.clamp(1, 8),
            layer_difference: opts.layer_difference.clamp(0, 255),
            mode: match opts.mode {
                0 => visioncortex::PathSimplifyMode::None,
                1 => visioncortex::PathSimplifyMode::Polygon,
                _ => visioncortex::PathSimplifyMode::Spline,
            },
            corner_threshold: opts.corner_threshold.clamp(0, 180),
            length_threshold: opts.length_threshold.clamp(3.5, 10.0),
            max_iterations: (opts.max_iterations as usize).clamp(1, 50),
            splice_threshold: opts.splice_threshold.clamp(0, 180),
            path_precision: Some(opts.path_precision.min(8)),
        };
        let svg = vtracer::convert(image, config)
            .map_err(|e| MorphError::new(MORPH_ERR_ENCODE, format!("trace failed: {e}")))?;
        unsafe { *out_svg = MorphBuffer::from_vec(svg.to_string().into_bytes()) };
        Ok(())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn svg_roundtrip() {
        let svg = br##"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20"><rect width="40" height="20" fill="#f00"/><text x="2" y="15" font-size="12">Hi</text></svg>"##;
        let mut buf = MorphBuffer { ptr: std::ptr::null_mut(), len: 0, cap: 0 };
        let (mut w, mut h) = (0u32, 0u32);
        let status = unsafe { morph_svg_render(svg.as_ptr(), svg.len(), 80, 0, &mut buf, &mut w, &mut h) };
        assert_eq!(status, MORPH_OK);
        assert_eq!((w, h), (80, 40));
        assert_eq!(buf.len, 80 * 40 * 4);
        unsafe { morph_buffer_free(buf) };
    }

    #[test]
    fn png_quantize_and_trace() {
        let (w, h) = (32u32, 32u32);
        let mut rgba = Vec::with_capacity((w * h * 4) as usize);
        for y in 0..h {
            for x in 0..w {
                rgba.extend_from_slice(&[(x * 8) as u8, (y * 8) as u8, 128, 255]);
            }
        }
        let opts = MorphPNGOptions {
            quality_min: 0,
            quality_max: 80,
            dithering: 1.0,
            speed: 4,
            optimization: 2,
            zopfli: false,
            premultiplied: false,
            icc: std::ptr::null(),
            icc_len: 0,
            timeout_ms: 0,
        };
        let mut png = MorphBuffer { ptr: std::ptr::null_mut(), len: 0, cap: 0 };
        let status = unsafe { morph_png_quantize(rgba.as_ptr(), w, h, &opts, &mut png) };
        assert_eq!(status, MORPH_OK);
        assert!(png.len > 8);
        unsafe { morph_buffer_free(png) };

        let trace = MorphTraceOptions {
            color: true,
            stacked: true,
            filter_speckle: 4,
            color_precision: 6,
            layer_difference: 16,
            mode: 2,
            corner_threshold: 60,
            length_threshold: 4.0,
            max_iterations: 10,
            splice_threshold: 45,
            path_precision: 2,
            premultiplied: false,
        };
        let mut svg = MorphBuffer { ptr: std::ptr::null_mut(), len: 0, cap: 0 };
        let status = unsafe { morph_trace_svg(rgba.as_ptr(), w, h, &trace, &mut svg) };
        assert_eq!(status, MORPH_OK);
        let text = unsafe { std::slice::from_raw_parts(svg.ptr, svg.len) };
        assert!(std::str::from_utf8(text).unwrap().contains("<svg"));
        unsafe { morph_buffer_free(svg) };
    }

    #[test]
    fn invalid_svg_reports_error() {
        let bad = b"<not svg";
        let mut buf = MorphBuffer { ptr: std::ptr::null_mut(), len: 0, cap: 0 };
        let (mut w, mut h) = (0u32, 0u32);
        let status = unsafe { morph_svg_render(bad.as_ptr(), bad.len(), 0, 0, &mut buf, &mut w, &mut h) };
        assert_eq!(status, MORPH_ERR_PARSE);
        assert!(!morph_last_error().is_null());
    }
}
