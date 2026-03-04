//! HTTP route definitions (simplified: no admin, no rate limiting)

use crate::{state::AppState, handlers, auth};
use axum::{
    Router,
    routing::{get, put, delete, post, head},
    middleware as axum_middleware,
    extract::DefaultBodyLimit,
};
use std::sync::Arc;
use tower_http::{
    cors::{CorsLayer, Any},
    trace::TraceLayer,
};
use axum::http::Method;

/// Create the main router
pub fn create_router(state: Arc<AppState>) -> Router {
    // Public routes (unauthenticated)
    let public = Router::new().route("/healthz", get(handlers::healthz));

    // Private (authenticated) routes
    let private = Router::new()
        // Service endpoints
        .route("/", get(handlers::list_buckets))
        .route("/", head(handlers::health_check))
        // Bucket endpoints (with and without trailing slash)
        .route("/{bucket}", put(handlers::create_bucket))
        .route("/{bucket}/", put(handlers::create_bucket))
        .route("/{bucket}", delete(handlers::delete_bucket))
        .route("/{bucket}/", delete(handlers::delete_bucket))
        .route("/{bucket}", head(handlers::head_bucket))
        .route("/{bucket}/", head(handlers::head_bucket))
        .route("/{bucket}", get(bucket_or_list_handler))
        .route("/{bucket}/", get(bucket_or_list_handler))
        .route("/{bucket}", post(bucket_post_handler))
        .route("/{bucket}/", post(bucket_post_handler))
        // Object endpoints
        .route("/{bucket}/{*key}", put(object_put_handler))
        .route("/{bucket}/{*key}", get(object_get_handler))
        .route("/{bucket}/{*key}", head(handlers::head_object))
        .route("/{bucket}/{*key}", delete(object_delete_handler))
        .route("/{bucket}/{*key}", post(object_post_handler))
        // Middleware layers
        .layer(axum_middleware::from_fn(auth::request_id_middleware))
        .layer(axum_middleware::from_fn(auth::logging_middleware))
        .layer(axum_middleware::from_fn_with_state(
            Arc::clone(&state),
            auth::auth_middleware,
        ))
        .with_state(state.clone());

    // CORS: allow everything (LAN only)
    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(vec![
            Method::GET, Method::PUT, Method::POST,
            Method::DELETE, Method::HEAD, Method::OPTIONS,
        ])
        .allow_headers(Any)
        .expose_headers(Any);

    Router::new()
        .merge(public)
        .merge(private)
        .layer(cors)
        .layer(TraceLayer::new_for_http())
        .layer(DefaultBodyLimit::max(state.config.max_body_size))
}

/// Handler that routes to list objects, list multipart uploads, or bucket location
async fn bucket_or_list_handler(
    state: axum::extract::State<Arc<AppState>>,
    session: axum::extract::Extension<crate::state::LocalSession>,
    path: axum::extract::Path<String>,
    query: axum::extract::Query<BucketQueryParams>,
) -> Result<axum::response::Response, crate::error::ApiError> {
    if query.uploads.is_some() {
        handlers::list_multipart_uploads(state, session, path).await
    } else if query.location.is_some() {
        handlers::get_bucket_location(state, session, path).await
    } else {
        let list_params = handlers::ListObjectsParams {
            list_type: query.list_type,
            prefix: query.prefix.clone(),
            delimiter: query.delimiter.clone(),
            max_keys: query.max_keys,
            continuation_token: query.continuation_token.clone(),
            start_after: query.start_after.clone(),
            fetch_owner: query.fetch_owner,
        };
        handlers::list_objects(state, session, path, axum::extract::Query(list_params)).await
    }
}

/// Handler for bucket POST operations (batch delete placeholder)
async fn bucket_post_handler(
    _state: axum::extract::State<Arc<AppState>>,
    _session: axum::extract::Extension<crate::state::LocalSession>,
    _path: axum::extract::Path<String>,
    query: axum::extract::Query<BucketQueryParams>,
) -> Result<axum::response::Response, crate::error::ApiError> {
    if query.delete.is_some() {
        // Batch delete not implemented in local gateway
        Err(crate::error::ApiError::s3(
            crate::error::S3ErrorCode::NotImplemented,
            "Batch delete not supported on local gateway",
        ))
    } else {
        Err(crate::error::ApiError::s3(
            crate::error::S3ErrorCode::InvalidRequest,
            "Invalid POST request on bucket",
        ))
    }
}

#[derive(Debug, serde::Deserialize)]
struct BucketQueryParams {
    uploads: Option<String>,
    location: Option<String>,
    delete: Option<String>,
    #[serde(rename = "list-type")]
    list_type: Option<u8>,
    prefix: Option<String>,
    delimiter: Option<String>,
    #[serde(rename = "max-keys")]
    max_keys: Option<usize>,
    #[serde(rename = "continuation-token")]
    continuation_token: Option<String>,
    #[serde(rename = "start-after")]
    start_after: Option<String>,
    #[serde(rename = "fetch-owner")]
    fetch_owner: Option<bool>,
}

/// Handler that routes PUT to copy_object, put_object, or upload_part
async fn object_put_handler(
    state: axum::extract::State<Arc<AppState>>,
    session: axum::extract::Extension<crate::state::LocalSession>,
    path: axum::extract::Path<(String, String)>,
    query: axum::extract::Query<ObjectQueryParams>,
    headers: axum::http::HeaderMap,
    body: bytes::Bytes,
) -> Result<axum::response::Response, crate::error::ApiError> {
    if query.part_number.is_some() && query.upload_id.is_some() {
        let mp_params = handlers::MultipartParams {
            upload_id: query.upload_id.clone(),
            part_number: query.part_number,
            uploads: query.uploads.clone(),
        };
        handlers::upload_part(state, session, path, axum::extract::Query(mp_params), headers, body).await
    } else if headers.contains_key("x-amz-copy-source") {
        handlers::copy_object(state, session, path, headers).await
    } else {
        handlers::put_object(state, session, path, headers, body).await
    }
}

#[derive(Debug, serde::Deserialize)]
struct ObjectQueryParams {
    #[serde(rename = "uploadId")]
    upload_id: Option<String>,
    #[serde(rename = "partNumber")]
    part_number: Option<u32>,
    uploads: Option<String>,
}

/// Handler for GET with optional uploadId parameter
async fn object_get_handler(
    state: axum::extract::State<Arc<AppState>>,
    session: axum::extract::Extension<crate::state::LocalSession>,
    path: axum::extract::Path<(String, String)>,
    query: axum::extract::Query<ObjectQueryParams>,
    headers: axum::http::HeaderMap,
) -> Result<axum::response::Response, crate::error::ApiError> {
    if query.upload_id.is_some() {
        let mp_params = handlers::MultipartParams {
            upload_id: query.upload_id.clone(),
            part_number: query.part_number,
            uploads: query.uploads.clone(),
        };
        handlers::list_parts(state, session, path, axum::extract::Query(mp_params)).await
    } else {
        handlers::get_object(state, session, path, headers).await
    }
}

/// Handler for DELETE with optional uploadId parameter
async fn object_delete_handler(
    state: axum::extract::State<Arc<AppState>>,
    session: axum::extract::Extension<crate::state::LocalSession>,
    path: axum::extract::Path<(String, String)>,
    query: axum::extract::Query<ObjectQueryParams>,
) -> Result<axum::response::Response, crate::error::ApiError> {
    if query.upload_id.is_some() {
        let mp_params = handlers::MultipartParams {
            upload_id: query.upload_id.clone(),
            part_number: query.part_number,
            uploads: query.uploads.clone(),
        };
        handlers::abort_multipart_upload(state, session, path, axum::extract::Query(mp_params)).await
    } else {
        handlers::delete_object(state, session, path).await
    }
}

/// Handler for POST (multipart operations)
async fn object_post_handler(
    state: axum::extract::State<Arc<AppState>>,
    session: axum::extract::Extension<crate::state::LocalSession>,
    path: axum::extract::Path<(String, String)>,
    query: axum::extract::Query<handlers::MultipartParams>,
    headers: axum::http::HeaderMap,
    body: bytes::Bytes,
) -> Result<axum::response::Response, crate::error::ApiError> {
    if query.uploads.is_some() {
        handlers::create_multipart_upload(state, session, path, headers).await
    } else if query.upload_id.is_some() {
        handlers::complete_multipart_upload(state, session, path, query, headers, body).await
    } else {
        Err(crate::error::ApiError::s3(
            crate::error::S3ErrorCode::InvalidRequest,
            "Invalid POST request",
        ))
    }
}
