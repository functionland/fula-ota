//! Error types and S3 error codes (simplified for local gateway)

use axum::{
    http::StatusCode,
    response::{IntoResponse, Response},
};
use thiserror::Error;

/// S3 error codes (subset relevant to local gateway)
#[derive(Debug, Clone, Copy)]
pub enum S3ErrorCode {
    AccessDenied,
    BucketAlreadyExists,
    BucketAlreadyOwnedByYou,
    BucketNotEmpty,
    EntityTooLarge,
    EntityTooSmall,
    InternalError,
    InvalidArgument,
    InvalidBucketName,
    InvalidDigest,
    InvalidPart,
    InvalidPartOrder,
    InvalidRange,
    InvalidRequest,
    KeyTooLong,
    MalformedXML,
    MethodNotAllowed,
    MissingContentLength,
    NoSuchBucket,
    NoSuchKey,
    NoSuchUpload,
    NotImplemented,
    OperationAborted,
    PreconditionFailed,
    RequestTimeout,
    ServiceUnavailable,
    TooManyBuckets,
}

impl S3ErrorCode {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::AccessDenied => "AccessDenied",
            Self::BucketAlreadyExists => "BucketAlreadyExists",
            Self::BucketAlreadyOwnedByYou => "BucketAlreadyOwnedByYou",
            Self::BucketNotEmpty => "BucketNotEmpty",
            Self::EntityTooLarge => "EntityTooLarge",
            Self::EntityTooSmall => "EntityTooSmall",
            Self::InternalError => "InternalError",
            Self::InvalidArgument => "InvalidArgument",
            Self::InvalidBucketName => "InvalidBucketName",
            Self::InvalidDigest => "InvalidDigest",
            Self::InvalidPart => "InvalidPart",
            Self::InvalidPartOrder => "InvalidPartOrder",
            Self::InvalidRange => "InvalidRange",
            Self::InvalidRequest => "InvalidRequest",
            Self::KeyTooLong => "KeyTooLong",
            Self::MalformedXML => "MalformedXML",
            Self::MethodNotAllowed => "MethodNotAllowed",
            Self::MissingContentLength => "MissingContentLength",
            Self::NoSuchBucket => "NoSuchBucket",
            Self::NoSuchKey => "NoSuchKey",
            Self::NoSuchUpload => "NoSuchUpload",
            Self::NotImplemented => "NotImplemented",
            Self::OperationAborted => "OperationAborted",
            Self::PreconditionFailed => "PreconditionFailed",
            Self::RequestTimeout => "RequestTimeout",
            Self::ServiceUnavailable => "ServiceUnavailable",
            Self::TooManyBuckets => "TooManyBuckets",
        }
    }

    pub fn status_code(&self) -> StatusCode {
        match self {
            Self::AccessDenied => StatusCode::FORBIDDEN,
            Self::BucketAlreadyExists | Self::BucketAlreadyOwnedByYou => StatusCode::CONFLICT,
            Self::BucketNotEmpty => StatusCode::CONFLICT,
            Self::EntityTooLarge | Self::EntityTooSmall => StatusCode::BAD_REQUEST,
            Self::InternalError => StatusCode::INTERNAL_SERVER_ERROR,
            Self::InvalidArgument
            | Self::InvalidBucketName
            | Self::InvalidDigest
            | Self::InvalidPart
            | Self::InvalidPartOrder
            | Self::InvalidRange
            | Self::InvalidRequest
            | Self::KeyTooLong
            | Self::MalformedXML
            | Self::MissingContentLength => StatusCode::BAD_REQUEST,
            Self::MethodNotAllowed => StatusCode::METHOD_NOT_ALLOWED,
            Self::NoSuchBucket | Self::NoSuchKey | Self::NoSuchUpload => StatusCode::NOT_FOUND,
            Self::NotImplemented => StatusCode::NOT_IMPLEMENTED,
            Self::OperationAborted | Self::PreconditionFailed => StatusCode::CONFLICT,
            Self::RequestTimeout => StatusCode::REQUEST_TIMEOUT,
            Self::ServiceUnavailable => StatusCode::SERVICE_UNAVAILABLE,
            Self::TooManyBuckets => StatusCode::BAD_REQUEST,
        }
    }
}

/// API error type
#[derive(Error, Debug)]
pub enum ApiError {
    #[error("S3 error: {code:?} - {message}")]
    S3Error {
        code: S3ErrorCode,
        message: String,
        resource: Option<String>,
        request_id: String,
    },

    #[error("Internal error: {0}")]
    Internal(String),

    #[error("Core error: {0}")]
    Core(#[from] fula_core::CoreError),

    #[error("Block store error: {0}")]
    BlockStore(#[from] fula_blockstore::BlockStoreError),
}

impl ApiError {
    pub fn s3(code: S3ErrorCode, message: impl Into<String>) -> Self {
        Self::S3Error {
            code,
            message: message.into(),
            resource: None,
            request_id: uuid::Uuid::new_v4().to_string(),
        }
    }

    pub fn s3_with_resource(
        code: S3ErrorCode,
        message: impl Into<String>,
        resource: impl Into<String>,
    ) -> Self {
        Self::S3Error {
            code,
            message: message.into(),
            resource: Some(resource.into()),
            request_id: uuid::Uuid::new_v4().to_string(),
        }
    }

    pub fn error_code(&self) -> S3ErrorCode {
        match self {
            Self::S3Error { code, .. } => *code,
            Self::Internal(_) => S3ErrorCode::InternalError,
            Self::Core(e) => match e {
                fula_core::CoreError::BucketNotFound(_) => S3ErrorCode::NoSuchBucket,
                fula_core::CoreError::BucketAlreadyExists(_) => S3ErrorCode::BucketAlreadyExists,
                fula_core::CoreError::ObjectNotFound { .. } => S3ErrorCode::NoSuchKey,
                fula_core::CoreError::InvalidBucketName(_) => S3ErrorCode::InvalidBucketName,
                fula_core::CoreError::AccessDenied(_) => S3ErrorCode::AccessDenied,
                fula_core::CoreError::PreconditionFailed(_) => S3ErrorCode::BucketNotEmpty,
                _ => S3ErrorCode::InternalError,
            },
            Self::BlockStore(_) => S3ErrorCode::InternalError,
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let code = self.error_code();
        let status = code.status_code();
        let request_id = match &self {
            ApiError::S3Error { request_id, .. } => request_id.clone(),
            _ => uuid::Uuid::new_v4().to_string(),
        };

        tracing::error!(
            error_code = %code.as_str(),
            status = %status,
            error = %self,
            "API error response"
        );

        let xml = format!(
            r#"<?xml version="1.0" encoding="UTF-8"?>
<Error>
    <Code>{}</Code>
    <Message>{}</Message>
    <RequestId>{}</RequestId>
</Error>"#,
            code.as_str(),
            self.to_string().replace('<', "&lt;").replace('>', "&gt;"),
            request_id
        );

        (
            status,
            [
                ("Content-Type", "application/xml"),
                ("x-amz-request-id", request_id.as_str()),
                ("x-amz-error-code", code.as_str()),
            ],
            xml,
        )
            .into_response()
    }
}
