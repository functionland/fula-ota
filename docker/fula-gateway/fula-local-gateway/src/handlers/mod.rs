//! S3 API request handlers for local gateway

pub mod bucket;
pub mod multipart;
pub mod object;
pub mod service;

pub use bucket::*;
pub use multipart::*;
pub use object::*;
pub use service::*;
