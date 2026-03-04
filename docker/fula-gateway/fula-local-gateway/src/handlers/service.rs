//! Service-level handlers (ListBuckets, healthz)

use crate::state::{AppState, LocalSession};
use crate::error::ApiError;
use crate::xml;
use axum::{
    extract::{Extension, State},
    response::{IntoResponse, Response},
    http::StatusCode,
};
use std::sync::Arc;

/// GET / - List buckets (S3 ListBuckets, always user-scoped)
pub async fn list_buckets(
    State(state): State<Arc<AppState>>,
    Extension(session): Extension<LocalSession>,
) -> Result<Response, ApiError> {
    let buckets = state.bucket_manager.list_buckets_for_user(&session.hashed_user_id);

    let user_buckets: Vec<_> = buckets
        .into_iter()
        .map(|b| (b.name, b.created_at))
        .collect();

    let xml_response = xml::list_all_my_buckets_result(
        &session.hashed_user_id,
        &session.display_name,
        &user_buckets,
    );

    Ok((
        StatusCode::OK,
        [("Content-Type", "application/xml")],
        xml_response,
    ).into_response())
}

/// HEAD / - Health check
pub async fn health_check() -> impl IntoResponse {
    (StatusCode::OK, "OK")
}

/// GET /healthz - unauthenticated container health check
pub async fn healthz() -> impl IntoResponse {
    (StatusCode::OK, "ok")
}
