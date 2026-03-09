use actix_web::{web, HttpResponse};
use image::codecs::jpeg::JpegEncoder;
use image::codecs::png::PngEncoder;
use image::{ImageEncoder, ImageReader};
use serde::Deserialize;
use std::io::Cursor;

const ALLOWED_DOMAINS: &[&str] = &["all-the.bufo.zone", "find-bufo.fly.dev"];
const DEFAULT_MAX_BYTES: usize = 900_000;

#[derive(Deserialize)]
pub struct ImageQuery {
    url: String,
    max_bytes: Option<usize>,
}

fn is_allowed_url(url: &str) -> bool {
    ALLOWED_DOMAINS
        .iter()
        .any(|domain| url.contains(domain))
}

pub async fn resize_image(query: web::Query<ImageQuery>) -> HttpResponse {
    let max_bytes = query.max_bytes.unwrap_or(DEFAULT_MAX_BYTES);

    if !is_allowed_url(&query.url) {
        return HttpResponse::BadRequest().body("domain not allowed");
    }

    // fetch original image
    let response = match reqwest::get(&query.url).await {
        Ok(r) => r,
        Err(e) => {
            tracing::error!("failed to fetch image: {}", e);
            return HttpResponse::BadGateway().body("failed to fetch image");
        }
    };

    if !response.status().is_success() {
        return HttpResponse::BadGateway().body("upstream returned error");
    }

    let content_type = response
        .headers()
        .get("content-type")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("application/octet-stream")
        .to_string();

    let bytes = match response.bytes().await {
        Ok(b) => b,
        Err(e) => {
            tracing::error!("failed to read image bytes: {}", e);
            return HttpResponse::BadGateway().body("failed to read image");
        }
    };

    // if already under limit, pass through
    if bytes.len() <= max_bytes {
        return HttpResponse::Ok()
            .insert_header(("content-type", content_type.as_str()))
            .insert_header(("cache-control", "public, max-age=86400"))
            .body(bytes);
    }

    tracing::info!(
        "image {} bytes exceeds {} limit, resizing",
        bytes.len(),
        max_bytes
    );

    let is_png = content_type.contains("png") || query.url.ends_with(".png");

    // try to decode the image
    let img = match ImageReader::new(Cursor::new(&bytes))
        .with_guessed_format()
        .and_then(|r| r.decode().map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e)))
    {
        Ok(img) => img,
        Err(e) => {
            tracing::error!("failed to decode image: {}", e);
            // return original if we can't decode
            return HttpResponse::Ok()
                .insert_header(("content-type", content_type.as_str()))
                .insert_header(("cache-control", "public, max-age=86400"))
                .body(bytes);
        }
    };

    if is_png {
        // try progressive resize as PNG
        for scale in &[75u32, 50, 25] {
            let new_w = img.width() * scale / 100;
            let new_h = img.height() * scale / 100;
            let resized = img.resize(new_w, new_h, image::imageops::FilterType::Lanczos3);

            let mut buf = Vec::new();
            if PngEncoder::new(&mut buf)
                .write_image(
                    resized.as_bytes(),
                    resized.width(),
                    resized.height(),
                    resized.color().into(),
                )
                .is_ok()
                && buf.len() <= max_bytes
            {
                tracing::info!("resized PNG to {}x{} ({}%), {} bytes", new_w, new_h, scale, buf.len());
                return HttpResponse::Ok()
                    .insert_header(("content-type", "image/png"))
                    .insert_header(("cache-control", "public, max-age=86400"))
                    .body(buf);
            }
        }

        // last resort: convert to JPEG
        for quality in &[85u8, 70, 50, 30] {
            let mut buf = Vec::new();
            if JpegEncoder::new_with_quality(&mut buf, *quality)
                .write_image(
                    img.as_bytes(),
                    img.width(),
                    img.height(),
                    img.color().into(),
                )
                .is_ok()
                && buf.len() <= max_bytes
            {
                tracing::info!("converted PNG to JPEG q={}, {} bytes", quality, buf.len());
                return HttpResponse::Ok()
                    .insert_header(("content-type", "image/jpeg"))
                    .insert_header(("cache-control", "public, max-age=86400"))
                    .body(buf);
            }
        }

        // if even JPEG conversion at lowest quality is too big, resize + JPEG
        for scale in &[75u32, 50, 25] {
            let new_w = img.width() * scale / 100;
            let new_h = img.height() * scale / 100;
            let resized = img.resize(new_w, new_h, image::imageops::FilterType::Lanczos3);

            let mut buf = Vec::new();
            if JpegEncoder::new_with_quality(&mut buf, 50)
                .write_image(
                    resized.as_bytes(),
                    resized.width(),
                    resized.height(),
                    resized.color().into(),
                )
                .is_ok()
                && buf.len() <= max_bytes
            {
                tracing::info!(
                    "resized+converted to JPEG {}x{} q=50, {} bytes",
                    new_w, new_h, buf.len()
                );
                return HttpResponse::Ok()
                    .insert_header(("content-type", "image/jpeg"))
                    .insert_header(("cache-control", "public, max-age=86400"))
                    .body(buf);
            }
        }
    } else {
        // JPEG: reduce quality progressively
        for quality in &[85u8, 70, 50, 30] {
            let mut buf = Vec::new();
            if JpegEncoder::new_with_quality(&mut buf, *quality)
                .write_image(
                    img.as_bytes(),
                    img.width(),
                    img.height(),
                    img.color().into(),
                )
                .is_ok()
                && buf.len() <= max_bytes
            {
                tracing::info!("re-encoded JPEG q={}, {} bytes", quality, buf.len());
                return HttpResponse::Ok()
                    .insert_header(("content-type", "image/jpeg"))
                    .insert_header(("cache-control", "public, max-age=86400"))
                    .body(buf);
            }
        }

        // resize + quality reduction
        for scale in &[75u32, 50, 25] {
            let new_w = img.width() * scale / 100;
            let new_h = img.height() * scale / 100;
            let resized = img.resize(new_w, new_h, image::imageops::FilterType::Lanczos3);

            let mut buf = Vec::new();
            if JpegEncoder::new_with_quality(&mut buf, 50)
                .write_image(
                    resized.as_bytes(),
                    resized.width(),
                    resized.height(),
                    resized.color().into(),
                )
                .is_ok()
                && buf.len() <= max_bytes
            {
                tracing::info!(
                    "resized JPEG to {}x{} q=50, {} bytes",
                    new_w, new_h, buf.len()
                );
                return HttpResponse::Ok()
                    .insert_header(("content-type", "image/jpeg"))
                    .insert_header(("cache-control", "public, max-age=86400"))
                    .body(buf);
            }
        }
    }

    // give up, return original
    tracing::warn!("could not resize image under {} bytes, returning original", max_bytes);
    HttpResponse::Ok()
        .insert_header(("content-type", content_type.as_str()))
        .insert_header(("cache-control", "public, max-age=86400"))
        .body(bytes)
}
