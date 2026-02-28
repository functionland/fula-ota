//! Multipart upload handlers (always user-scoped, always unified DAG)

use crate::state::{AppState, LocalSession};
use crate::error::{ApiError, S3ErrorCode};
use crate::multipart_manager::UploadPart;
use crate::xml;
use super::object::try_decode_chunked;
use axum::{
    extract::{Extension, Path, Query, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
};
use bytes::Bytes;
use fula_blockstore::{BlockStore, PinStore};
use fula_core::metadata::ObjectMetadata;
use serde::Deserialize;
use serde_json::json;
use std::sync::Arc;

/// Query params for multipart operations
#[derive(Debug, Deserialize)]
pub struct MultipartParams {
    #[serde(rename = "uploadId")]
    pub upload_id: Option<String>,
    #[serde(rename = "partNumber")]
    pub part_number: Option<u32>,
    pub uploads: Option<String>,
}

/// POST /{bucket}/{key}?uploads - Initiate multipart upload
pub async fn create_multipart_upload(
    State(state): State<Arc<AppState>>,
    Extension(session): Extension<LocalSession>,
    Path((bucket, key)): Path<(String, String)>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    if !state.bucket_manager.bucket_exists_for_user(&session.hashed_user_id, &bucket) {
        return Err(ApiError::s3(S3ErrorCode::NoSuchBucket, "Bucket not found"));
    }

    let content_type = headers.get("Content-Type")
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string());

    let mut metadata = std::collections::BTreeMap::new();
    for (name, value) in headers.iter() {
        if let Some(meta_key) = name.as_str().strip_prefix("x-amz-meta-") {
            if let Ok(v) = value.to_str() {
                metadata.insert(meta_key.to_string(), v.to_string());
            }
        }
    }

    let upload = state.multipart_manager.create_upload_with_metadata(
        bucket.clone(),
        key.clone(),
        session.hashed_user_id.clone(),
        content_type,
        metadata,
    );

    let xml_response = xml::initiate_multipart_upload_result(&bucket, &key, &upload.upload_id);

    Ok((
        StatusCode::OK,
        [("Content-Type", "application/xml")],
        xml_response,
    ).into_response())
}

/// PUT /{bucket}/{key}?partNumber=N&uploadId=X - Upload part
pub async fn upload_part(
    State(state): State<Arc<AppState>>,
    Extension(_session): Extension<LocalSession>,
    Path((bucket, key)): Path<(String, String)>,
    Query(params): Query<MultipartParams>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Response, ApiError> {
    let upload_id = params.upload_id
        .ok_or_else(|| ApiError::s3(S3ErrorCode::InvalidArgument, "Missing uploadId"))?;
    let part_number = params.part_number
        .ok_or_else(|| ApiError::s3(S3ErrorCode::InvalidArgument, "Missing partNumber"))?;

    if !(1..=10000).contains(&part_number) {
        return Err(ApiError::s3(S3ErrorCode::InvalidArgument, "Part number must be between 1 and 10000"));
    }

    let upload = state.multipart_manager.get_upload(&upload_id)
        .ok_or_else(|| ApiError::s3(S3ErrorCode::NoSuchUpload, "Upload not found"))?;

    if upload.bucket != bucket || upload.key != key {
        return Err(ApiError::s3(S3ErrorCode::InvalidArgument, "Bucket/key mismatch"));
    }

    let body = match try_decode_chunked(&headers, &body) {
        Some(decoded) => decoded,
        None => body,
    };

    let cid = state.block_store.put_block(&body).await?;
    let etag = cid.to_string();

    let part = UploadPart::new(part_number, etag.clone(), body.len() as u64, cid.to_string());
    state.multipart_manager.add_part(&upload_id, part);

    Ok((
        StatusCode::OK,
        [("ETag", format!("\"{}\"", etag))],
        "",
    ).into_response())
}

/// POST /{bucket}/{key}?uploadId=X - Complete multipart upload
pub async fn complete_multipart_upload(
    State(state): State<Arc<AppState>>,
    Extension(session): Extension<LocalSession>,
    Path((bucket, key)): Path<(String, String)>,
    Query(params): Query<MultipartParams>,
    _headers: HeaderMap,
    _body: Bytes,
) -> Result<Response, ApiError> {
    let upload_id = params.upload_id
        .ok_or_else(|| ApiError::s3(S3ErrorCode::InvalidArgument, "Missing uploadId"))?;

    let upload = state.multipart_manager.complete_upload(&upload_id)
        .ok_or_else(|| ApiError::s3(S3ErrorCode::NoSuchUpload, "Upload not found"))?;

    if upload.bucket != bucket || upload.key != key {
        return Err(ApiError::s3(S3ErrorCode::InvalidArgument, "Bucket/key mismatch"));
    }

    // Collect part CIDs
    let part_cids: Vec<cid::Cid> = upload.parts.values()
        .filter_map(|p| p.cid.parse().ok())
        .collect();

    if part_cids.is_empty() {
        return Err(ApiError::s3(S3ErrorCode::InvalidPart, "No parts uploaded"));
    }

    // Create unified DAG linking all parts via put_ipld
    let final_cid = if part_cids.len() == 1 {
        part_cids[0]
    } else {
        let cid_strings: Vec<String> = part_cids.iter().map(|c| c.to_string()).collect();
        let dag_node = json!({
            "type": "fula-multipart-file",
            "parts": cid_strings,
        });
        state.block_store.put_ipld(&dag_node).await
            .map_err(|e| ApiError::Internal(format!("Failed to create unified DAG: {}", e)))?
    };

    // Compute multipart ETag: {blake3_hash}-{part_count}
    let part_count = upload.parts.len();
    let mut cid_concat = String::new();
    for part in upload.sorted_parts() {
        cid_concat.push_str(&part.cid);
    }
    let hash = blake3::hash(cid_concat.as_bytes());
    let hash_hex = hex::encode(&hash.as_bytes()[..16]);
    let final_etag = format!("{}-{}", hash_hex, part_count);

    let total_size: u64 = upload.parts.values().map(|p| p.size).sum();

    let mut metadata = ObjectMetadata::new(final_cid, total_size, final_etag.clone())
        .with_owner(&session.hashed_user_id);

    if let Some(ct) = upload.content_type {
        metadata = metadata.with_content_type(ct);
    }
    for (k, v) in upload.metadata {
        metadata = metadata.with_user_metadata(k, v);
    }

    // Store in bucket (user-scoped)
    let mut bucket_handle = state.bucket_manager.open_bucket_for_user(&session.hashed_user_id, &bucket).await?;
    bucket_handle.put_object(key.clone(), metadata).await?;
    let bucket_root_cid = bucket_handle.flush().await?;

    // Persist registry
    if let Err(e) = state.bucket_manager.persist_registry().await {
        tracing::warn!(error = %e, "Failed to persist registry after complete_multipart_upload");
    }

    // Pin bucket root (fire-and-forget)
    {
        let block_store = Arc::clone(&state.block_store);
        let pin_bucket = bucket.clone();
        tokio::spawn(async move {
            let pin_name = format!("bucket:{}", pin_bucket);
            if let Err(e) = block_store.pin(&bucket_root_cid, Some(&pin_name)).await {
                tracing::warn!(cid = %bucket_root_cid, error = %e, "Failed to pin bucket root CID");
            }
        });
    }

    let location = format!("/{}/{}", bucket, key);
    let xml_response = xml::complete_multipart_upload_result(&location, &bucket, &key, &final_etag);

    Ok((
        StatusCode::OK,
        [
            ("Content-Type", "application/xml"),
            ("X-Fula-Content-Cid", &final_cid.to_string()),
        ],
        xml_response,
    ).into_response())
}

/// DELETE /{bucket}/{key}?uploadId=X - Abort multipart upload
pub async fn abort_multipart_upload(
    State(state): State<Arc<AppState>>,
    Extension(_session): Extension<LocalSession>,
    Path((bucket, key)): Path<(String, String)>,
    Query(params): Query<MultipartParams>,
) -> Result<Response, ApiError> {
    let upload_id = params.upload_id
        .ok_or_else(|| ApiError::s3(S3ErrorCode::InvalidArgument, "Missing uploadId"))?;

    let upload = state.multipart_manager.abort_upload(&upload_id)
        .ok_or_else(|| ApiError::s3(S3ErrorCode::NoSuchUpload, "Upload not found"))?;

    if upload.bucket != bucket || upload.key != key {
        return Err(ApiError::s3(S3ErrorCode::InvalidArgument, "Bucket/key mismatch"));
    }

    Ok(StatusCode::NO_CONTENT.into_response())
}

/// GET /{bucket}/{key}?uploadId=X - List parts
pub async fn list_parts(
    State(state): State<Arc<AppState>>,
    Extension(_session): Extension<LocalSession>,
    Path((bucket, key)): Path<(String, String)>,
    Query(params): Query<MultipartParams>,
) -> Result<Response, ApiError> {
    let upload_id = params.upload_id
        .ok_or_else(|| ApiError::s3(S3ErrorCode::InvalidArgument, "Missing uploadId"))?;

    let parts = state.multipart_manager.list_parts(&upload_id)
        .ok_or_else(|| ApiError::s3(S3ErrorCode::NoSuchUpload, "Upload not found"))?;

    let xml_response = xml::list_parts_result(&bucket, &key, &upload_id, &parts, false, 1000);

    Ok((
        StatusCode::OK,
        [("Content-Type", "application/xml")],
        xml_response,
    ).into_response())
}

/// GET /{bucket}?uploads - List multipart uploads
pub async fn list_multipart_uploads(
    State(state): State<Arc<AppState>>,
    Extension(_session): Extension<LocalSession>,
    Path(bucket): Path<String>,
) -> Result<Response, ApiError> {
    let uploads = state.multipart_manager.list_uploads(&bucket);

    let xml_response = xml::list_multipart_uploads_result(&bucket, &uploads, false, 1000);

    Ok((
        StatusCode::OK,
        [("Content-Type", "application/xml")],
        xml_response,
    ).into_response())
}
