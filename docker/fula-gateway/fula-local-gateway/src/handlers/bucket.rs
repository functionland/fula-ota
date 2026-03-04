//! Bucket operation handlers (always user-scoped)

use crate::state::{AppState, LocalSession};
use crate::error::{ApiError, S3ErrorCode};
use crate::xml;
use axum::{
    extract::{Extension, Path, Query, State},
    response::{IntoResponse, Response},
    http::StatusCode,
};
use fula_core::metadata::Owner;
use serde::Deserialize;
use std::sync::Arc;

/// PUT /{bucket} - Create bucket
pub async fn create_bucket(
    State(state): State<Arc<AppState>>,
    Extension(session): Extension<LocalSession>,
    Path(bucket): Path<String>,
) -> Result<Response, ApiError> {
    let owner = Owner::new(&session.hashed_user_id)
        .with_display_name(&session.display_name);

    state.bucket_manager.create_bucket_for_user(
        &session.hashed_user_id,
        bucket.clone(),
        owner,
    ).await?;

    // Persist registry after mutation
    if let Err(e) = state.bucket_manager.persist_registry().await {
        tracing::warn!(error = %e, "Failed to persist registry after create_bucket");
    }

    Ok((
        StatusCode::OK,
        [("Location", format!("/{}", bucket))],
        "",
    ).into_response())
}

/// DELETE /{bucket} - Delete bucket
pub async fn delete_bucket(
    State(state): State<Arc<AppState>>,
    Extension(session): Extension<LocalSession>,
    Path(bucket): Path<String>,
) -> Result<Response, ApiError> {
    state.bucket_manager.delete_bucket_for_user(&session.hashed_user_id, &bucket).await?;

    if let Err(e) = state.bucket_manager.persist_registry().await {
        tracing::warn!(error = %e, "Failed to persist registry after delete_bucket");
    }

    Ok(StatusCode::NO_CONTENT.into_response())
}

/// HEAD /{bucket} - Check if bucket exists
pub async fn head_bucket(
    State(state): State<Arc<AppState>>,
    Extension(session): Extension<LocalSession>,
    Path(bucket): Path<String>,
) -> Result<Response, ApiError> {
    if !state.bucket_manager.bucket_exists_for_user(&session.hashed_user_id, &bucket) {
        return Err(ApiError::s3(S3ErrorCode::NoSuchBucket, "Bucket not found"));
    }
    Ok(StatusCode::OK.into_response())
}

/// Query parameters for ListObjectsV2
#[derive(Debug, Deserialize)]
pub struct ListObjectsParams {
    #[allow(dead_code)]
    #[serde(rename = "list-type")]
    pub list_type: Option<u8>,
    pub prefix: Option<String>,
    pub delimiter: Option<String>,
    #[serde(rename = "max-keys")]
    pub max_keys: Option<usize>,
    #[serde(rename = "continuation-token")]
    pub continuation_token: Option<String>,
    #[serde(rename = "start-after")]
    pub start_after: Option<String>,
    #[allow(dead_code)]
    #[serde(rename = "fetch-owner")]
    pub fetch_owner: Option<bool>,
}

/// GET /{bucket} - List objects (ListObjectsV2)
pub async fn list_objects(
    State(state): State<Arc<AppState>>,
    Extension(session): Extension<LocalSession>,
    Path(bucket_name): Path<String>,
    Query(params): Query<ListObjectsParams>,
) -> Result<Response, ApiError> {
    let bucket = state.bucket_manager.open_bucket_for_user(&session.hashed_user_id, &bucket_name).await?;

    let result = bucket.list_objects(
        params.prefix.as_deref(),
        params.delimiter.as_deref(),
        params.start_after.as_deref().or(params.continuation_token.as_deref()),
        params.max_keys,
    ).await?;

    let objects: Vec<_> = result.objects
        .iter()
        .map(|o| (o.key.clone(), &o.metadata))
        .collect();

    let xml_response = xml::list_bucket_result(
        &bucket_name,
        &result.prefix,
        result.delimiter.as_deref(),
        result.max_keys,
        result.is_truncated,
        &objects,
        &result.common_prefixes,
        params.continuation_token.as_deref(),
        result.next_continuation_token.as_deref(),
    );

    Ok((
        StatusCode::OK,
        [("Content-Type", "application/xml")],
        xml_response,
    ).into_response())
}

/// GET /{bucket}?location - Get bucket location
pub async fn get_bucket_location(
    State(state): State<Arc<AppState>>,
    Extension(session): Extension<LocalSession>,
    Path(bucket): Path<String>,
) -> Result<Response, ApiError> {
    if !state.bucket_manager.bucket_exists_for_user(&session.hashed_user_id, &bucket) {
        return Err(ApiError::s3(S3ErrorCode::NoSuchBucket, "Bucket not found"));
    }

    let xml_response = r#"<?xml version="1.0" encoding="UTF-8"?>
<LocationConstraint xmlns="http://s3.amazonaws.com/doc/2006-03-01/"></LocationConstraint>"#;

    Ok((
        StatusCode::OK,
        [("Content-Type", "application/xml")],
        xml_response,
    ).into_response())
}
