//! JPEG encoding for preview frames and recordings, through GDI+ (which the
//! app starts at launch, `gfx::startup`), and the image helpers around it.

use windows::Win32::Graphics::GdiPlus::{
    EncoderParameter, EncoderParameters, GdipCreateBitmapFromScan0, GdipDisposeImage, GdipSaveImageToStream, GpBitmap, GpImage, Status,
};
use windows::Win32::System::Com::{STREAM_SEEK_END, STREAM_SEEK_SET};
use windows::Win32::UI::Shell::SHCreateMemStream;
use windows::core::GUID;

/// GDI+'s built-in JPEG encoder ("image/jpeg").
const JPEG_ENCODER: GUID = GUID::from_u128(0x557cf401_1a04_11d3_9a73_0000f81ef32e);
/// EncoderQuality: a long from 0 to 100.
const ENCODER_QUALITY: GUID = GUID::from_u128(0x1d5be4b5_fa4a_452d_9cdd_5db35105e7eb);
const PARAMETER_TYPE_LONG: u32 = 4;
const PIXEL_FORMAT_32BPP_RGB: i32 = 0x22009;

/// A picture: 32-bit BGRA rows, top-down, no padding.
pub struct Bgra {
    pub w: i32,
    pub h: i32,
    pub bits: Vec<u8>,
}

/// Encode as JPEG, `quality` from 0 to 1.
pub fn encode(img: &Bgra, quality: f32) -> Result<Vec<u8>, String> {
    if img.w <= 0 || img.h <= 0 || img.bits.len() < (img.w * img.h * 4) as usize {
        return Err("no picture".into());
    }
    unsafe {
        let mut bmp: *mut GpBitmap = std::ptr::null_mut();
        let st = GdipCreateBitmapFromScan0(img.w, img.h, img.w * 4, PIXEL_FORMAT_32BPP_RGB, Some(img.bits.as_ptr()), &mut bmp);
        if st != Status(0) || bmp.is_null() {
            return Err(format!("GDI+ couldn't take the picture ({})", st.0));
        }
        let result = (|| {
            let stream = SHCreateMemStream(None).ok_or("no memory stream")?;
            let mut q = (quality.clamp(0.0, 1.0) * 100.0).round() as u32;
            let params = EncoderParameters {
                Count: 1,
                Parameter: [EncoderParameter { Guid: ENCODER_QUALITY, NumberOfValues: 1, Type: PARAMETER_TYPE_LONG, Value: &mut q as *mut u32 as *mut _ }],
            };
            let st = GdipSaveImageToStream(bmp as *mut GpImage, &stream, &JPEG_ENCODER, &params);
            if st != Status(0) {
                return Err(format!("GDI+ couldn't encode a JPEG ({})", st.0));
            }
            let mut size = 0u64;
            stream.Seek(0, STREAM_SEEK_END, Some(&mut size)).map_err(|e| e.to_string())?;
            stream.Seek(0, STREAM_SEEK_SET, None).map_err(|e| e.to_string())?;
            let mut out = vec![0u8; size as usize];
            let mut read = 0u32;
            stream.Read(out.as_mut_ptr() as *mut _, size as u32, Some(&mut read)).ok().map_err(|e| e.to_string())?;
            out.truncate(read as usize);
            Ok(out)
        })();
        let _ = GdipDisposeImage(bmp as *mut GpImage);
        result
    }
}

/// `img` scaled to `w` x `h`, averaging the source pixels each one covers.
pub fn scale(img: &Bgra, w: i32, h: i32) -> Bgra {
    if w == img.w && h == img.h {
        return Bgra { w, h, bits: img.bits.clone() };
    }
    let (sw, sh) = (img.w as usize, img.h as usize);
    let (dw, dh) = (w.max(1) as usize, h.max(1) as usize);
    let mut bits = vec![0u8; dw * dh * 4];
    for y in 0..dh {
        let y0 = y * sh / dh;
        let y1 = ((y + 1) * sh / dh).max(y0 + 1).min(sh);
        for x in 0..dw {
            let x0 = x * sw / dw;
            let x1 = ((x + 1) * sw / dw).max(x0 + 1).min(sw);
            let mut sum = [0u32; 4];
            for sy in y0..y1 {
                let row = &img.bits[(sy * sw + x0) * 4..(sy * sw + x1) * 4];
                for p in row.chunks_exact(4) {
                    for c in 0..4 {
                        sum[c] += p[c] as u32;
                    }
                }
            }
            let n = ((y1 - y0) * (x1 - x0)) as u32;
            let o = (y * dw + x) * 4;
            for c in 0..4 {
                bits[o + c] = (sum[c] / n) as u8;
            }
        }
    }
    Bgra { w: w.max(1), h: h.max(1), bits }
}

/// The size to show `w` x `h` at, no wider than `max_width`.
pub fn fit(w: i32, h: i32, max_width: i32) -> (i32, i32) {
    if w <= max_width || w <= 0 {
        return (w, h);
    }
    (max_width, ((h as i64 * max_width as i64) / w as i64).max(1) as i32)
}

/// A quick fingerprint of the pixels, to skip sending a frame that didn't change.
pub fn fingerprint(bits: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for chunk in bits.chunks_exact(8) {
        h ^= u64::from_le_bytes(chunk.try_into().unwrap());
        h = h.wrapping_mul(0x0000_0100_0000_01b3).rotate_left(29);
    }
    h
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scaling_averages() {
        // 2x2 to 1x1: the average of the four.
        let img = Bgra { w: 2, h: 2, bits: vec![0, 0, 0, 255, 100, 100, 100, 255, 200, 200, 200, 255, 100, 100, 100, 255] };
        let s = scale(&img, 1, 1);
        assert_eq!(s.bits, vec![100, 100, 100, 255]);
        assert_eq!(fit(3200, 2000, 1600), (1600, 1000));
        assert_eq!(fit(1600, 1000, 1600), (1600, 1000));
    }

    #[test]
    fn fingerprints_differ() {
        let a = vec![0u8; 64];
        let mut b = a.clone();
        b[40] = 1;
        assert_ne!(fingerprint(&a), fingerprint(&b));
        assert_eq!(fingerprint(&a), fingerprint(&a.clone()));
    }
}
