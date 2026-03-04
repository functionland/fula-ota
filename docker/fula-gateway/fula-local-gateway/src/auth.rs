//! Bearer-only auth middleware for local gateway.
//!
//! - If bearer_secret is configured: require `Authorization: Bearer <secret>`
//! - If not configured (unpaired): allow all requests (safe behind LAN firewall)

use crate::state::{AppState, LocalSession};
use crate::error::{ApiError, S3ErrorCode};
use axum::{
    body::Body,
    extract::State,
    http::Request,
    middleware::Next,
    response::Response,
};
use std::sync::Arc;

/// Bearer-only authentication middleware
pub async fn auth_middleware(
    State(state): State<Arc<AppState>>,
    mut request: Request<Body>,
    next: Next,
) -> Result<Response, ApiError> {
    let session = match &state.config.bearer_secret {
        Some(secret) => {
            // Bearer secret configured: require valid Authorization header
            let auth_header = request
                .headers()
                .get("Authorization")
                .and_then(|h| h.to_str().ok());

            match auth_header {
                Some(header) => {
                    let token = header
                        .strip_prefix("Bearer ")
                        .ok_or_else(|| {
                            ApiError::s3(S3ErrorCode::AccessDenied, "Use 'Authorization: Bearer <secret>'")
                        })?;

                    if !constant_time_eq(token.as_bytes(), secret.as_bytes()) {
                        return Err(ApiError::s3(S3ErrorCode::AccessDenied, "Invalid bearer token"));
                    }

                    create_local_session(&state)
                }
                None => {
                    return Err(ApiError::s3(
                        S3ErrorCode::AccessDenied,
                        "Authentication required. Use 'Authorization: Bearer <secret>'",
                    ));
                }
            }
        }
        None => {
            // No bearer secret (unpaired device): allow all requests
            create_local_session(&state)
        }
    };

    request.extensions_mut().insert(session);
    Ok(next.run(request).await)
}

fn create_local_session(state: &AppState) -> LocalSession {
    LocalSession {
        hashed_user_id: state
            .config
            .owner_id
            .clone()
            .unwrap_or_else(|| "local-device".to_string()),
        display_name: "Local Device".to_string(),
    }
}

/// Constant-time byte comparison to prevent timing side-channels
fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.iter()
        .zip(b.iter())
        .fold(0u8, |acc, (x, y)| acc | (x ^ y))
        == 0
}

/// Request ID middleware - adds x-amz-request-id header
pub async fn request_id_middleware(
    request: Request<Body>,
    next: Next,
) -> Response {
    let request_id = uuid::Uuid::new_v4().to_string();
    let mut response = next.run(request).await;
    response.headers_mut().insert(
        "x-amz-request-id",
        request_id.parse().unwrap(),
    );
    response
}

/// Logging middleware
pub async fn logging_middleware(
    request: Request<Body>,
    next: Next,
) -> Response {
    let method = request.method().clone();
    let uri = request.uri().clone();
    let start = std::time::Instant::now();
    let response = next.run(request).await;
    let duration = start.elapsed();
    tracing::info!(
        method = %method,
        uri = %uri,
        status = %response.status().as_u16(),
        duration_ms = %duration.as_millis(),
        "Request completed"
    );
    response
}
