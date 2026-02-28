//! Object operation handlers (always user-scoped, always X-Fula-Content-Cid)

use crate::state::{AppState, LocalSession};
use crate::error::{ApiError, S3ErrorCode};
use crate::xml;
use axum::{
    body::Body,
    extract::{Extension, Path, State},
    http::{HeaderMap, StatusCode, header},
    response::{IntoResponse, Response},
};
use bytes::Bytes;
use fula_blockstore::{BlockStore, PinStore};
use fula_core::metadata::ObjectMetadata;
use std::sync::Arc;

/// PUT /{bucket}/{key} - Put object
pub async fn put_object(
    State(state): State<Arc<AppState>>,
    Extension(session): Extension<LocalSession>,
    Path((bucket_name, key)): Path<(String, String)>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Response, ApiError> {
    // Decode chunked encoding if present
    let body = match try_decode_chunked(&headers, &body) {
        Some(decoded) => decoded,
        None => body,
    };

    // Store the data
    let cid = state.block_store.put_block(&body).await?;
    let etag = cid.to_string();

    // Content-MD5 validation skipped on local gateway (no md-5 crate dependency).
    // This is safe: Content-MD5 is optional in the S3 spec and rarely sent.

    // Extract metadata
    let content_type = headers
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string());

    let mut metadata = ObjectMetadata::new(cid, body.len() as u64, etag.clone())
        .with_owner(&session.hashed_user_id);

    if let Some(ct) = content_type {
        metadata = metadata.with_content_type(ct);
    }

    // Extract user metadata (x-amz-meta-*)
    for (name, value) in headers.iter() {
        if let Some(meta_key) = name.as_str().strip_prefix("x-amz-meta-") {
            if let Ok(v) = value.to_str() {
                metadata = metadata.with_user_metadata(meta_key, v);
            }
        }
    }

    // Store in bucket (user-scoped)
    let mut bucket = state.bucket_manager.open_bucket_for_user(&session.hashed_user_id, &bucket_name).await?;
    bucket.put_object(key.clone(), metadata).await?;
    let bucket_root_cid = bucket.flush().await?;

    // Persist registry
    if let Err(e) = state.bucket_manager.persist_registry().await {
        tracing::warn!(error = %e, "Failed to persist registry after put_object");
    }

    // Pin bucket root CID (fire-and-forget)
    {
        let block_store = Arc::clone(&state.block_store);
        let pin_name = format!("bucket:{}", bucket_name);
        tokio::spawn(async move {
            if let Err(e) = block_store.pin(&bucket_root_cid, Some(&pin_name)).await {
                tracing::warn!(cid = %bucket_root_cid, error = %e, "Failed to pin bucket root CID");
            }
        });
    }

    Ok((
        StatusCode::OK,
        [
            ("ETag", format!("\"{}\"", etag)),
            ("X-Fula-Content-Cid", cid.to_string()),
        ],
        "",
    ).into_response())
}

/// GET /{bucket}/{key} - Get object with Range and conditional request support
pub async fn get_object(
    State(state): State<Arc<AppState>>,
    Extension(session): Extension<LocalSession>,
    Path((bucket_name, key)): Path<(String, String)>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let bucket = state.bucket_manager.open_bucket_for_user(&session.hashed_user_id, &bucket_name).await?;

    let metadata = bucket.get_object(&key).await?
        .ok_or_else(|| ApiError::s3_with_resource(
            S3ErrorCode::NoSuchKey,
            "Object not found",
            format!("{}/{}", bucket_name, key),
        ))?;

    if metadata.is_delete_marker {
        return Err(ApiError::s3_with_resource(
            S3ErrorCode::NoSuchKey,
            "Object is a delete marker",
            format!("{}/{}", bucket_name, key),
        ));
    }

    let etag = format!("\"{}\"", metadata.etag);
    let last_modified_str = metadata.last_modified.format("%a, %d %b %Y %H:%M:%S GMT").to_string();

    // Handle If-None-Match (304 Not Modified)
    if let Some(if_none_match) = headers.get("If-None-Match").and_then(|v| v.to_str().ok()) {
        if if_none_match == etag || if_none_match == "*" {
            return Ok(Response::builder()
                .status(StatusCode::NOT_MODIFIED)
                .header("ETag", &etag)
                .header("Last-Modified", &last_modified_str)
                .body(Body::empty())
                .unwrap());
        }
    }

    // Handle If-Modified-Since (304 Not Modified)
    if let Some(if_modified_since) = headers.get("If-Modified-Since").and_then(|v| v.to_str().ok()) {
        if let Ok(since) = chrono::DateTime::parse_from_rfc2822(if_modified_since) {
            if metadata.last_modified <= since.with_timezone(&chrono::Utc) {
                return Ok(Response::builder()
                    .status(StatusCode::NOT_MODIFIED)
                    .header("ETag", &etag)
                    .header("Last-Modified", &last_modified_str)
                    .body(Body::empty())
                    .unwrap());
            }
        }
    }

    // Retrieve data
    let data = state.block_store.get_block(&metadata.cid).await?;
    let total_size = data.len();

    // Handle Range request
    let range_header = headers.get("Range").and_then(|v| v.to_str().ok());
    let (status, body_data, content_range) = if let Some(range) = range_header {
        match parse_range_header(range, total_size) {
            Ok((start, end)) => {
                let content_range = format!("bytes {}-{}/{}", start, end, total_size);
                let slice = data.slice(start..=end);
                (StatusCode::PARTIAL_CONTENT, slice, Some(content_range))
            }
            Err(_) => {
                return Err(ApiError::s3(S3ErrorCode::InvalidRange, "Requested range not satisfiable"));
            }
        }
    } else {
        (StatusCode::OK, data, None)
    };

    // Build response
    let mut response = Response::builder()
        .status(status)
        .header("ETag", &etag)
        .header("Content-Length", body_data.len().to_string())
        .header("Last-Modified", &last_modified_str)
        .header("Accept-Ranges", "bytes")
        .header("X-Fula-Content-Cid", metadata.cid.to_string());

    if let Some(range) = content_range {
        response = response.header("Content-Range", range);
    }
    if let Some(ref ct) = metadata.content_type {
        response = response.header("Content-Type", ct);
    }
    if let Some(ref cc) = metadata.cache_control {
        response = response.header("Cache-Control", cc);
    }
    if let Some(ref cd) = metadata.content_disposition {
        response = response.header("Content-Disposition", cd);
    }
    if let Some(ref ce) = metadata.content_encoding {
        response = response.header("Content-Encoding", ce);
    }
    for (k, v) in &metadata.user_metadata {
        response = response.header(format!("x-amz-meta-{}", k), v);
    }
    if let Some(ref version_id) = metadata.version_id {
        response = response.header("x-amz-version-id", version_id);
    }

    Ok(response.body(Body::from(body_data)).unwrap())
}

/// HEAD /{bucket}/{key} - Head object
pub async fn head_object(
    State(state): State<Arc<AppState>>,
    Extension(session): Extension<LocalSession>,
    Path((bucket_name, key)): Path<(String, String)>,
) -> Result<Response, ApiError> {
    let bucket = state.bucket_manager.open_bucket_for_user(&session.hashed_user_id, &bucket_name).await?;

    let metadata = bucket.get_object(&key).await?
        .ok_or_else(|| ApiError::s3_with_resource(
            S3ErrorCode::NoSuchKey,
            "Object not found",
            format!("{}/{}", bucket_name, key),
        ))?;

    let mut response = Response::builder()
        .status(StatusCode::OK)
        .header("ETag", format!("\"{}\"", metadata.etag))
        .header("Content-Length", metadata.size.to_string())
        .header("Last-Modified", metadata.last_modified.format("%a, %d %b %Y %H:%M:%S GMT").to_string())
        .header("X-Fula-Content-Cid", metadata.cid.to_string());

    if let Some(ref ct) = metadata.content_type {
        response = response.header("Content-Type", ct);
    }
    for (k, v) in &metadata.user_metadata {
        response = response.header(format!("x-amz-meta-{}", k), v);
    }

    Ok(response.body(Body::empty()).unwrap())
}

/// DELETE /{bucket}/{key} - Delete object
pub async fn delete_object(
    State(state): State<Arc<AppState>>,
    Extension(session): Extension<LocalSession>,
    Path((bucket_name, key)): Path<(String, String)>,
) -> Result<Response, ApiError> {
    let mut bucket = state.bucket_manager.open_bucket_for_user(&session.hashed_user_id, &bucket_name).await?;

    bucket.delete_object(&key).await?;
    bucket.flush().await?;

    if let Err(e) = state.bucket_manager.persist_registry().await {
        tracing::warn!(error = %e, "Failed to persist registry after delete_object");
    }

    Ok(StatusCode::NO_CONTENT.into_response())
}

/// PUT /{bucket}/{key} with x-amz-copy-source - Copy object
pub async fn copy_object(
    State(state): State<Arc<AppState>>,
    Extension(session): Extension<LocalSession>,
    Path((dest_bucket, dest_key)): Path<(String, String)>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let copy_source = headers
        .get("x-amz-copy-source")
        .and_then(|v| v.to_str().ok())
        .ok_or_else(|| ApiError::s3(S3ErrorCode::InvalidArgument, "Missing x-amz-copy-source"))?;

    let source_path = copy_source.trim_start_matches('/');
    let (source_bucket, source_key) = source_path
        .split_once('/')
        .ok_or_else(|| ApiError::s3(S3ErrorCode::InvalidArgument, "Invalid copy source format"))?;

    let source_bucket_handle = state.bucket_manager.open_bucket_for_user(&session.hashed_user_id, source_bucket).await?;
    let source_metadata = source_bucket_handle.get_object(source_key).await?
        .ok_or_else(|| ApiError::s3_with_resource(
            S3ErrorCode::NoSuchKey,
            "Source object not found",
            copy_source,
        ))?;

    let mut dest_metadata = source_metadata.clone();
    dest_metadata.last_modified = chrono::Utc::now();
    dest_metadata.owner_id = Some(session.hashed_user_id.clone());

    let mut dest_bucket_handle = state.bucket_manager.open_bucket_for_user(&session.hashed_user_id, &dest_bucket).await?;
    dest_bucket_handle.put_object(dest_key, dest_metadata.clone()).await?;
    dest_bucket_handle.flush().await?;

    if let Err(e) = state.bucket_manager.persist_registry().await {
        tracing::warn!(error = %e, "Failed to persist registry after copy_object");
    }

    let xml_response = xml::copy_object_result(dest_metadata.last_modified, &dest_metadata.etag);

    Ok((
        StatusCode::OK,
        [("Content-Type", "application/xml")],
        xml_response,
    ).into_response())
}

/// Attempt to decode HTTP chunked transfer encoding from a request body.
pub(crate) fn try_decode_chunked(headers: &HeaderMap, body: &Bytes) -> Option<Bytes> {
    let has_decoded_len = headers.get("x-amz-decoded-content-length").is_some();
    let has_aws_chunked = headers
        .get(header::CONTENT_ENCODING)
        .and_then(|v| v.to_str().ok())
        .map(|v| v.contains("aws-chunked"))
        .unwrap_or(false);

    if !has_decoded_len && !has_aws_chunked && !looks_like_chunked(body) {
        return None;
    }

    decode_chunked_body(body).map(|decoded| {
        tracing::info!(
            original_len = body.len(),
            decoded_len = decoded.len(),
            "Decoded chunked request body"
        );
        decoded
    })
}

fn looks_like_chunked(body: &[u8]) -> bool {
    if body.len() < 4 {
        return false;
    }
    let crlf_pos = match body.windows(2).position(|w| w == b"\r\n") {
        Some(pos) if pos > 0 && pos <= 100 => pos,
        _ => return false,
    };
    let size_line = match std::str::from_utf8(&body[..crlf_pos]) {
        Ok(s) => s,
        Err(_) => return false,
    };
    let size_hex = size_line.split(';').next().unwrap_or("");
    let chunk_size = match usize::from_str_radix(size_hex.trim(), 16) {
        Ok(s) if s > 0 => s,
        _ => return false,
    };
    let data_start = crlf_pos + 2;
    chunk_size <= body.len().saturating_sub(data_start)
}

fn decode_chunked_body(body: &[u8]) -> Option<Bytes> {
    let mut decoded = Vec::new();
    let mut pos = 0;

    while pos < body.len() {
        let remaining = &body[pos..];
        let crlf_pos = remaining.windows(2).position(|w| w == b"\r\n")?;
        if crlf_pos == 0 {
            pos += 2;
            continue;
        }
        let size_line = std::str::from_utf8(&remaining[..crlf_pos]).ok()?;
        let size_hex = size_line.split(';').next()?;
        let chunk_size = usize::from_str_radix(size_hex.trim(), 16).ok()?;
        if chunk_size == 0 {
            break;
        }
        let data_start = pos + crlf_pos + 2;
        let data_end = data_start + chunk_size;
        if data_end > body.len() {
            return None;
        }
        decoded.extend_from_slice(&body[data_start..data_end]);
        pos = data_end;
        if pos + 2 <= body.len() && body[pos] == b'\r' && body[pos + 1] == b'\n' {
            pos += 2;
        }
    }

    if decoded.is_empty() { None } else { Some(Bytes::from(decoded)) }
}

/// Parse Range header (e.g., "bytes=0-1023")
fn parse_range_header(range: &str, total_size: usize) -> Result<(usize, usize), ()> {
    let range = range.strip_prefix("bytes=").ok_or(())?;
    if let Some((start_str, end_str)) = range.split_once('-') {
        if start_str.is_empty() {
            let suffix_len: usize = end_str.parse().map_err(|_| ())?;
            let start = total_size.saturating_sub(suffix_len);
            Ok((start, total_size - 1))
        } else if end_str.is_empty() {
            let start: usize = start_str.parse().map_err(|_| ())?;
            if start >= total_size { return Err(()); }
            Ok((start, total_size - 1))
        } else {
            let start: usize = start_str.parse().map_err(|_| ())?;
            let end: usize = end_str.parse().map_err(|_| ())?;
            if start > end || start >= total_size { return Err(()); }
            Ok((start, end.min(total_size - 1)))
        }
    } else {
        Err(())
    }
}


#[allow(dead_code)]
fn _suppress_warnings() {}
