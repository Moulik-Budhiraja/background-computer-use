//! Drawing for the tray icon, the popover and the expanded view: GDI+ into a
//! 32-bit DIB, in logical pixels (scaled for the monitor's DPI), then copied
//! to the window. UI thread only.

use std::cell::RefCell;
use std::collections::HashMap;

use windows::Win32::Foundation::RECT;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::Graphics::GdiPlus::*;
use windows::Win32::Storage::FileSystem::FILE_FLAGS_AND_ATTRIBUTES;
use windows::Win32::UI::Shell::{SHFILEINFOW, SHGFI_ICON, SHGFI_LARGEICON, SHGFI_SMALLICON, SHGetFileInfoW};
use windows::Win32::UI::WindowsAndMessaging::{CreateIconIndirect, DI_NORMAL, DrawIconEx, HICON, ICONINFO};
use windows::core::{HSTRING, PCWSTR};

const PIXEL_FORMAT_32BPP_RGB: i32 = 0x22009;
const PIXEL_FORMAT_32BPP_ARGB: i32 = 0x26200A;
const PIXEL_FORMAT_32BPP_PARGB: i32 = 0xE200B;

pub fn startup() {
    let input = GdiplusStartupInput { GdiplusVersion: 1, ..Default::default() };
    let mut token = 0usize;
    unsafe {
        let _ = GdiplusStartup(&mut token, &input, std::ptr::null_mut());
    }
}

/// 0xAARRGGBB.
pub type Color = u32;

pub const fn rgb(hex: u32) -> Color {
    0xFF00_0000 | hex
}

pub const fn rgba(hex: u32, alpha: f32) -> Color {
    (((alpha * 255.0) as u32) << 24) | (hex & 0xFF_FFFF)
}

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub enum Font {
    Semibold,
    /// Segoe Fluent Icons (Windows 11) or Segoe MDL2 Assets (Windows 10).
    Icons,
}

#[derive(Clone, Copy, PartialEq)]
pub enum Align {
    Left,
    Center,
}

struct Fonts {
    families: HashMap<Font, usize>,
    fonts: HashMap<(Font, u32), usize>,
    format: usize,
}

thread_local! {
    static FONTS: RefCell<Option<Fonts>> = const { RefCell::new(None) };
    static ICONS: RefCell<HashMap<String, Option<usize>>> = RefCell::new(HashMap::new());
}

fn family(font: Font) -> *mut GpFontFamily {
    let names: &[&str] = match font {
        Font::Semibold => &["Segoe UI Variable Text Semibold", "Segoe UI Semibold", "Segoe UI"],
        Font::Icons => &["Segoe Fluent Icons", "Segoe MDL2 Assets"],
    };
    for name in names {
        let mut f = std::ptr::null_mut();
        let h = HSTRING::from(*name);
        if unsafe { GdipCreateFontFamilyFromName(PCWSTR(h.as_ptr()), std::ptr::null_mut(), &mut f) } == Ok && !f.is_null() {
            return f;
        }
    }
    std::ptr::null_mut()
}

fn with_fonts<R>(f: impl FnOnce(&mut Fonts) -> R) -> R {
    FONTS.with(|cell| {
        let mut slot = cell.borrow_mut();
        let fonts = slot.get_or_insert_with(|| {
            let mut format = std::ptr::null_mut();
            unsafe {
                // GenericTypographic: no padding around the text, so it sits where it's put.
                let mut generic = std::ptr::null_mut();
                let _ = GdipStringFormatGetGenericTypographic(&mut generic);
                let _ = GdipCloneStringFormat(generic, &mut format);
                let _ = GdipSetStringFormatFlags(format, StringFormatFlagsNoWrap.0 | StringFormatFlagsNoClip.0);
                let _ = GdipSetStringFormatTrimming(format, StringTrimmingEllipsisCharacter);
            }
            Fonts { families: HashMap::new(), fonts: HashMap::new(), format: format as usize }
        });
        f(fonts)
    })
}

fn font(kind: Font, size: f32) -> (*mut GpFont, *mut GpStringFormat) {
    with_fonts(|fonts| {
        let key = (kind, (size * 100.0) as u32);
        let fam = *fonts.families.entry(kind).or_insert_with(|| family(kind) as usize) as *mut GpFontFamily;
        let font = *fonts.fonts.entry(key).or_insert_with(|| {
            let mut f = std::ptr::null_mut();
            unsafe {
                let _ = GdipCreateFont(fam, size, FontStyleRegular.0, UnitPixel, &mut f);
            }
            f as usize
        });
        (font as *mut GpFont, fonts.format as *mut GpStringFormat)
    })
}

/// A picture to draw: 32-bit BGRA rows, top-down.
pub struct Frame {
    pub w: i32,
    pub h: i32,
    pub bits: Vec<u8>,
}

/// Copy a rectangle of the screen, scaled to w x h. Works for the agent
/// monitors, which no one sees but DWM still composes.
pub fn capture_screen(src: RECT, w: i32, h: i32) -> Option<Frame> {
    if w <= 0 || h <= 0 {
        return None;
    }
    unsafe {
        let screen = GetDC(None);
        let mem = CreateCompatibleDC(Some(screen));
        let info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER { biSize: size_of::<BITMAPINFOHEADER>() as u32, biWidth: w, biHeight: -h, biPlanes: 1, biBitCount: 32, ..Default::default() },
            ..Default::default()
        };
        let mut bits = std::ptr::null_mut();
        let std::result::Result::Ok(bmp) = CreateDIBSection(Some(mem), &info, DIB_RGB_COLORS, &mut bits, None, 0) else {
            let _ = DeleteDC(mem);
            ReleaseDC(None, screen);
            return None;
        };
        let old = SelectObject(mem, bmp.into());
        let (sw, sh) = (src.right - src.left, src.bottom - src.top);
        let ok = if sw == w && sh == h {
            BitBlt(mem, 0, 0, w, h, Some(screen), src.left, src.top, SRCCOPY).is_ok()
        } else {
            SetStretchBltMode(mem, HALFTONE);
            let _ = SetBrushOrgEx(mem, 0, 0, None);
            StretchBlt(mem, 0, 0, w, h, Some(screen), src.left, src.top, sw, sh, SRCCOPY).as_bool()
        };
        let frame = ok.then(|| Frame { w, h, bits: std::slice::from_raw_parts(bits as *const u8, (w * h * 4) as usize).to_vec() });
        SelectObject(mem, old);
        let _ = DeleteObject(bmp.into());
        let _ = DeleteDC(mem);
        ReleaseDC(None, screen);
        frame
    }
}

/// A hidden screen isn't on any display, so there's nothing to copy: draw
/// each window on it from its own surface (as screenshots do), bottom first,
/// then scale to w x h.
pub fn capture_windows(src: RECT, w: i32, h: i32) -> Option<Frame> {
    let (sw, sh) = (src.right - src.left, src.bottom - src.top);
    if w <= 0 || h <= 0 || sw <= 0 || sh <= 0 {
        return None;
    }
    let mut canvas = vec![0u8; (sw * sh * 4) as usize];
    // EnumWindows lists the top first.
    for hwnd in crate::win::top_level_windows().into_iter().rev() {
        if !crate::win::is_visible(hwnd) || crate::win::is_minimized(hwnd) {
            continue;
        }
        let f = crate::win::frame(hwnd);
        if f.right <= src.left || f.left >= src.right || f.bottom <= src.top || f.top >= src.bottom {
            continue;
        }
        let std::result::Result::Ok(img) = crate::capture::window(hwnd, f) else { continue };
        let (ox, oy) = (f.left - src.left, f.top - src.top);
        for y in 0..img.height as i32 {
            let cy = oy + y;
            if cy < 0 || cy >= sh {
                continue;
            }
            let x0 = ox.max(0);
            let x1 = (ox + img.width as i32).min(sw);
            if x1 <= x0 {
                continue;
            }
            let from = ((y * img.width as i32 + (x0 - ox)) * 4) as usize;
            let to = ((cy * sw + x0) * 4) as usize;
            let n = ((x1 - x0) * 4) as usize;
            canvas[to..to + n].copy_from_slice(&img.bgra[from..from + n]);
        }
    }
    unsafe {
        let screen = GetDC(None);
        let mem = CreateCompatibleDC(Some(screen));
        let info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER { biSize: size_of::<BITMAPINFOHEADER>() as u32, biWidth: w, biHeight: -h, biPlanes: 1, biBitCount: 32, ..Default::default() },
            ..Default::default()
        };
        let mut bits = std::ptr::null_mut();
        let std::result::Result::Ok(bmp) = CreateDIBSection(Some(mem), &info, DIB_RGB_COLORS, &mut bits, None, 0) else {
            let _ = DeleteDC(mem);
            ReleaseDC(None, screen);
            return None;
        };
        let old = SelectObject(mem, bmp.into());
        let src_info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER { biSize: size_of::<BITMAPINFOHEADER>() as u32, biWidth: sw, biHeight: -sh, biPlanes: 1, biBitCount: 32, ..Default::default() },
            ..Default::default()
        };
        SetStretchBltMode(mem, HALFTONE);
        let _ = SetBrushOrgEx(mem, 0, 0, None);
        let ok = StretchDIBits(mem, 0, 0, w, h, 0, 0, sw, sh, Some(canvas.as_ptr() as *const _), &src_info, DIB_RGB_COLORS, SRCCOPY) != 0;
        let frame = ok.then(|| Frame { w, h, bits: std::slice::from_raw_parts(bits as *const u8, (w * h * 4) as usize).to_vec() });
        SelectObject(mem, old);
        let _ = DeleteObject(bmp.into());
        let _ = DeleteDC(mem);
        ReleaseDC(None, screen);
        frame
    }
}

/// A drawing surface. Coordinates are logical pixels; `scale` is the DPI scale.
pub struct Canvas {
    pub w: i32,
    pub h: i32,
    pub scale: f32,
    dc: HDC,
    bmp: HBITMAP,
    old: HGDIOBJ,
    image: *mut GpBitmap,
    g: *mut GpGraphics,
}

impl Canvas {
    /// `w` x `h` device pixels.
    pub fn new(w: i32, h: i32, scale: f32) -> Canvas {
        Self::with_format(w, h, scale, PIXEL_FORMAT_32BPP_PARGB)
    }

    /// With straight alpha, for icons.
    pub fn new_icon(size: i32) -> Canvas {
        Self::with_format(size, size, 1.0, PIXEL_FORMAT_32BPP_ARGB)
    }

    fn with_format(w: i32, h: i32, scale: f32, format: i32) -> Canvas {
        unsafe {
            let dc = CreateCompatibleDC(None);
            let info = BITMAPINFO {
                bmiHeader: BITMAPINFOHEADER { biSize: size_of::<BITMAPINFOHEADER>() as u32, biWidth: w.max(1), biHeight: -h.max(1), biPlanes: 1, biBitCount: 32, ..Default::default() },
                ..Default::default()
            };
            let mut bits = std::ptr::null_mut();
            let bmp = CreateDIBSection(Some(dc), &info, DIB_RGB_COLORS, &mut bits, None, 0).unwrap_or_default();
            let old = SelectObject(dc, bmp.into());
            let mut image = std::ptr::null_mut();
            let _ = GdipCreateBitmapFromScan0(w.max(1), h.max(1), w.max(1) * 4, format, Some(bits as *const u8), &mut image);
            let mut g = std::ptr::null_mut();
            let _ = GdipGetImageGraphicsContext(image as *mut GpImage, &mut g);
            let _ = GdipSetSmoothingMode(g, SmoothingModeAntiAlias);
            let _ = GdipSetPixelOffsetMode(g, PixelOffsetModeHalf);
            let _ = GdipSetTextRenderingHint(g, TextRenderingHintAntiAliasGridFit);
            let _ = GdipSetInterpolationMode(g, InterpolationModeHighQualityBicubic);
            let _ = GdipScaleWorldTransform(g, scale, scale, MatrixOrderAppend);
            Canvas { w, h, scale, dc, bmp, old, image, g }
        }
    }

    pub fn clear(&self, color: Color) {
        unsafe {
            let _ = GdipGraphicsClear(self.g, color);
        }
    }

    fn brush(color: Color) -> *mut GpBrush {
        let mut b = std::ptr::null_mut();
        unsafe {
            let _ = GdipCreateSolidFill(color, &mut b);
        }
        b as *mut GpBrush
    }

    fn rounded_path(x: f32, y: f32, w: f32, h: f32, r: f32) -> *mut GpPath {
        let mut p = std::ptr::null_mut();
        let r = r.min(w / 2.0).min(h / 2.0);
        unsafe {
            let _ = GdipCreatePath(FillModeWinding, &mut p);
            if r <= 0.0 {
                let _ = GdipAddPathRectangle(p, x, y, w, h);
            } else {
                let d = r * 2.0;
                let _ = GdipAddPathArc(p, x, y, d, d, 180.0, 90.0);
                let _ = GdipAddPathArc(p, x + w - d, y, d, d, 270.0, 90.0);
                let _ = GdipAddPathArc(p, x + w - d, y + h - d, d, d, 0.0, 90.0);
                let _ = GdipAddPathArc(p, x, y + h - d, d, d, 90.0, 90.0);
                let _ = GdipClosePathFigure(p);
            }
        }
        p
    }

    pub fn fill_round(&self, x: f32, y: f32, w: f32, h: f32, r: f32, color: Color) {
        unsafe {
            let p = Self::rounded_path(x, y, w, h, r);
            let b = Self::brush(color);
            let _ = GdipFillPath(self.g, b, p);
            let _ = GdipDeleteBrush(b);
            let _ = GdipDeletePath(p);
        }
    }

    pub fn stroke_round(&self, x: f32, y: f32, w: f32, h: f32, r: f32, color: Color, width: f32, dash: Option<&[f32]>) {
        unsafe {
            let p = Self::rounded_path(x + width / 2.0, y + width / 2.0, w - width, h - width, r);
            let mut pen = std::ptr::null_mut();
            let _ = GdipCreatePen1(color, width, UnitWorld, &mut pen);
            if let Some(d) = dash {
                let _ = GdipSetPenDashArray(pen, d.as_ptr(), d.len() as i32);
            }
            let _ = GdipDrawPath(self.g, pen, p);
            let _ = GdipDeletePen(pen);
            let _ = GdipDeletePath(p);
        }
    }

    pub fn fill_circle(&self, cx: f32, cy: f32, r: f32, color: Color) {
        unsafe {
            let b = Self::brush(color);
            let _ = GdipFillEllipse(self.g, b, cx - r, cy - r, r * 2.0, r * 2.0);
            let _ = GdipDeleteBrush(b);
        }
    }

    pub fn stroke_circle(&self, cx: f32, cy: f32, r: f32, color: Color, width: f32) {
        unsafe {
            let mut pen = std::ptr::null_mut();
            let _ = GdipCreatePen1(color, width, UnitWorld, &mut pen);
            let _ = GdipDrawEllipse(self.g, pen, cx - r, cy - r, r * 2.0, r * 2.0);
            let _ = GdipDeletePen(pen);
        }
    }

    pub fn fill_rect(&self, x: f32, y: f32, w: f32, h: f32, color: Color) {
        unsafe {
            let b = Self::brush(color);
            let _ = GdipFillRectangle(self.g, b, x, y, w, h);
            let _ = GdipDeleteBrush(b);
        }
    }

    fn polygon_path(points: &[(f32, f32)]) -> *mut GpPath {
        let pts: Vec<PointF> = points.iter().map(|&(x, y)| PointF { X: x, Y: y }).collect();
        let mut p = std::ptr::null_mut();
        unsafe {
            let _ = GdipCreatePath(FillModeWinding, &mut p);
            let _ = GdipAddPathPolygon(p, pts.as_ptr(), pts.len() as i32);
        }
        p
    }

    pub fn fill_polygon(&self, points: &[(f32, f32)], color: Color) {
        unsafe {
            let p = Self::polygon_path(points);
            let b = Self::brush(color);
            let _ = GdipFillPath(self.g, b, p);
            let _ = GdipDeleteBrush(b);
            let _ = GdipDeletePath(p);
        }
    }

    pub fn stroke_polygon(&self, points: &[(f32, f32)], color: Color, width: f32) {
        unsafe {
            let p = Self::polygon_path(points);
            let mut pen = std::ptr::null_mut();
            let _ = GdipCreatePen1(color, width, UnitWorld, &mut pen);
            let _ = GdipSetPenLineJoin(pen, LineJoinRound);
            let _ = GdipDrawPath(self.g, pen, p);
            let _ = GdipDeletePen(pen);
            let _ = GdipDeletePath(p);
        }
    }

    /// Erase (to transparent) along a polygon's outline, for icons.
    pub fn clear_polygon_outline(&self, points: &[(f32, f32)], width: f32) {
        unsafe {
            let _ = GdipSetCompositingMode(self.g, CompositingModeSourceCopy);
            self.stroke_polygon(points, 0, width);
            let _ = GdipSetCompositingMode(self.g, CompositingModeSourceOver);
        }
    }

    /// Erase (to transparent) a disc, for icons.
    pub fn clear_circle(&self, cx: f32, cy: f32, r: f32) {
        unsafe {
            let _ = GdipSetCompositingMode(self.g, CompositingModeSourceCopy);
            self.fill_circle(cx, cy, r, 0);
            let _ = GdipSetCompositingMode(self.g, CompositingModeSourceOver);
        }
    }

    pub fn measure(&self, text: &str, kind: Font, size: f32) -> f32 {
        let (f, format) = font(kind, size);
        let w: Vec<u16> = text.encode_utf16().collect();
        let layout = RectF { X: 0.0, Y: 0.0, Width: 10000.0, Height: 1000.0 };
        let mut out = RectF::default();
        unsafe {
            let _ = GdipMeasureString(self.g, PCWSTR(w.as_ptr()), w.len() as i32, f, &layout, format, &mut out, std::ptr::null_mut(), std::ptr::null_mut());
        }
        out.Width
    }

    /// One line of text, vertically centered on `cy`, cut with "…" past `max_w`.
    pub fn text(&self, text: &str, x: f32, cy: f32, max_w: f32, kind: Font, size: f32, color: Color, align: Align) {
        let (f, format) = font(kind, size);
        let w: Vec<u16> = text.encode_utf16().collect();
        let h = size * 1.6;
        let x0 = match align {
            Align::Left => x,
            Align::Center => x - max_w / 2.0,
        };
        let layout = RectF { X: x0, Y: cy - h / 2.0, Width: max_w, Height: h };
        unsafe {
            let _ = GdipSetStringFormatAlign(
                format,
                match align {
                    Align::Left => StringAlignmentNear,
                    Align::Center => StringAlignmentCenter,
                },
            );
            let _ = GdipSetStringFormatLineAlign(format, StringAlignmentCenter);
            let b = Self::brush(color);
            let _ = GdipDrawString(self.g, PCWSTR(w.as_ptr()), w.len() as i32, f, &layout, format, b);
            let _ = GdipDeleteBrush(b);
            let _ = GdipSetStringFormatAlign(format, StringAlignmentNear);
        }
    }

    /// An icon from the icon font, centered on (cx, cy).
    pub fn glyph(&self, code: u32, cx: f32, cy: f32, size: f32, color: Color) {
        let s = char::from_u32(code).map(String::from).unwrap_or_default();
        self.text(&s, cx, cy, size * 2.0, Font::Icons, size, color, Align::Center);
    }

    /// A picture filling a rounded rectangle; the frame is in device pixels.
    pub fn image_round(&self, frame: &Frame, x: f32, y: f32, w: f32, h: f32, r: f32) {
        unsafe {
            let mut img = std::ptr::null_mut();
            if GdipCreateBitmapFromScan0(frame.w, frame.h, frame.w * 4, PIXEL_FORMAT_32BPP_RGB, Some(frame.bits.as_ptr()), &mut img) != Ok {
                return;
            }
            let mut tex = std::ptr::null_mut();
            let _ = GdipCreateTexture(img as *mut GpImage, WrapModeClamp, &mut tex);
            // Texture pixels to logical pixels, then to the rectangle.
            let _ = GdipScaleTextureTransform(tex, w / frame.w as f32, h / frame.h as f32, MatrixOrderAppend);
            let _ = GdipTranslateTextureTransform(tex, x, y, MatrixOrderAppend);
            let p = Self::rounded_path(x, y, w, h, r);
            let _ = GdipFillPath(self.g, tex as *mut GpBrush, p);
            let _ = GdipDeletePath(p);
            let _ = GdipDeleteBrush(tex as *mut GpBrush);
            let _ = GdipDisposeImage(img as *mut GpImage);
        }
    }

    /// An app's icon (from its exe), `size` logical pixels square.
    pub fn app_icon(&self, exe: &str, x: f32, y: f32, size: f32) -> bool {
        let Some(icon) = icon_for(exe, size * self.scale > 20.0) else { return false };
        unsafe {
            let _ = GdipFlush(self.g, FlushIntentionSync);
            let s = (size * self.scale).round() as i32;
            let _ = DrawIconEx(self.dc, (x * self.scale).round() as i32, (y * self.scale).round() as i32, icon, s, s, 0, None, DI_NORMAL);
            let _ = GdiFlush();
        }
        true
    }

    /// Copy to a window's DC at (0, 0).
    pub fn present(&self, hdc: HDC) {
        unsafe {
            let _ = GdipFlush(self.g, FlushIntentionSync);
            let _ = BitBlt(hdc, 0, 0, self.w, self.h, Some(self.dc), 0, 0, SRCCOPY);
        }
    }

    /// Make an icon of what's drawn (straight-alpha canvases).
    pub fn into_icon(self) -> HICON {
        unsafe {
            let _ = GdipFlush(self.g, FlushIntentionSync);
            SelectObject(self.dc, self.old);
            let mask_bits = vec![0u8; (((self.w + 15) / 16 * 2) * self.h) as usize];
            let mask = CreateBitmap(self.w, self.h, 1, 1, Some(mask_bits.as_ptr() as *const _));
            let info = ICONINFO { fIcon: true.into(), xHotspot: 0, yHotspot: 0, hbmMask: mask, hbmColor: self.bmp };
            let icon = CreateIconIndirect(&info).unwrap_or_default();
            let _ = DeleteObject(mask.into());
            SelectObject(self.dc, self.bmp.into());
            icon
        }
    }
}

impl Drop for Canvas {
    fn drop(&mut self) {
        unsafe {
            let _ = GdipDeleteGraphics(self.g);
            let _ = GdipDisposeImage(self.image as *mut GpImage);
            SelectObject(self.dc, self.old);
            let _ = DeleteObject(self.bmp.into());
            let _ = DeleteDC(self.dc);
        }
    }
}

fn icon_for(exe: &str, large: bool) -> Option<HICON> {
    if exe.is_empty() {
        return None;
    }
    let key = format!("{exe}|{large}");
    ICONS.with(|cache| {
        *cache.borrow_mut().entry(key).or_insert_with(|| {
            let mut info = SHFILEINFOW::default();
            let path = HSTRING::from(exe);
            let flags = SHGFI_ICON | if large { SHGFI_LARGEICON } else { SHGFI_SMALLICON };
            let ok = unsafe { SHGetFileInfoW(PCWSTR(path.as_ptr()), FILE_FLAGS_AND_ATTRIBUTES(0), Some(&mut info), size_of::<SHFILEINFOW>() as u32, flags) };
            (ok != 0 && !info.hIcon.is_invalid()).then_some(info.hIcon.0 as usize)
        })
    })
    .map(|h| HICON(h as *mut _))
}
