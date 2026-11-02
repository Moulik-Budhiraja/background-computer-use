//! Window screenshots. PrintWindow with PW_RENDERFULLCONTENT reads the window's
//! own surface from the compositor, so it works for windows nobody can see and
//! shows no capture border.

use windows::Win32::Foundation::{HWND, RECT};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::Storage::Xps::{PRINT_WINDOW_FLAGS, PrintWindow};
use windows::Win32::UI::WindowsAndMessaging::GetWindowRect;

pub struct Image {
    pub width: u32,
    pub height: u32,
    pub bgra: Vec<u8>,
}

const PW_RENDERFULLCONTENT: u32 = 2;

/// The window's visible frame (`frame`, screen pixels), without the invisible borders.
pub fn window(hwnd: HWND, frame: RECT) -> Result<Image, String> {
    unsafe {
        let mut r = RECT::default();
        GetWindowRect(hwnd, &mut r).map_err(|e| e.to_string())?;
        let (w, h) = (r.right - r.left, r.bottom - r.top);
        if w <= 0 || h <= 0 {
            return Err("the window has no size".into());
        }
        let screen = GetDC(None);
        let mem = CreateCompatibleDC(Some(screen));
        let info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: w,
                biHeight: -h,
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        let mut bits = std::ptr::null_mut();
        let bmp = CreateDIBSection(Some(screen), &info, DIB_RGB_COLORS, &mut bits, None, 0).map_err(|e| e.to_string())?;
        let old = SelectObject(mem, bmp.into());
        let ok = PrintWindow(hwnd, mem, PRINT_WINDOW_FLAGS(PW_RENDERFULLCONTENT)).as_bool();
        let all = std::slice::from_raw_parts(bits as *const u8, (w * h * 4) as usize);
        // Crop to the visible frame.
        let x0 = (frame.left - r.left).clamp(0, w);
        let y0 = (frame.top - r.top).clamp(0, h);
        let x1 = (frame.right - r.left).clamp(x0, w);
        let y1 = (frame.bottom - r.top).clamp(y0, h);
        let (cw, ch) = ((x1 - x0) as usize, (y1 - y0) as usize);
        let mut bgra = Vec::with_capacity(cw * ch * 4);
        for y in y0..y1 {
            let start = ((y * w + x0) * 4) as usize;
            bgra.extend_from_slice(&all[start..start + cw * 4]);
        }
        SelectObject(mem, old);
        let _ = DeleteObject(bmp.into());
        let _ = DeleteDC(mem);
        ReleaseDC(None, screen);
        if !ok {
            return Err("PrintWindow failed".into());
        }
        Ok(Image { width: cw as u32, height: ch as u32, bgra })
    }
}

pub fn png(img: &Image) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    {
        let mut enc = png::Encoder::new(&mut out, img.width, img.height);
        enc.set_color(png::ColorType::Rgb);
        enc.set_depth(png::BitDepth::Eight);
        enc.set_compression(png::Compression::Fast);
        let mut writer = enc.write_header().map_err(|e| e.to_string())?;
        let rgb: Vec<u8> = img.bgra.chunks_exact(4).flat_map(|p| [p[2], p[1], p[0]]).collect();
        writer.write_image_data(&rgb).map_err(|e| e.to_string())?;
    }
    Ok(out)
}

pub fn base64(data: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let n = (chunk[0] as u32) << 16 | (*chunk.get(1).unwrap_or(&0) as u32) << 8 | *chunk.get(2).unwrap_or(&0) as u32;
        out.push(T[(n >> 18) as usize & 63] as char);
        out.push(T[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { T[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { T[n as usize & 63] as char } else { '=' });
    }
    out
}

#[cfg(test)]
mod tests {
    #[test]
    fn base64_matches_known_values() {
        assert_eq!(super::base64(b""), "");
        assert_eq!(super::base64(b"f"), "Zg==");
        assert_eq!(super::base64(b"fo"), "Zm8=");
        assert_eq!(super::base64(b"foobar"), "Zm9vYmFy");
    }
}
