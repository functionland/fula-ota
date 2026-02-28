//! Multipart upload management

use chrono::{DateTime, Utc, Duration};
use dashmap::DashMap;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use tracing::{debug, warn};
use uuid::Uuid;

/// Multipart upload state
#[derive(Clone, Debug)]
pub struct MultipartUpload {
    pub upload_id: String,
    pub bucket: String,
    pub key: String,
    pub owner_id: String,
    pub created_at: DateTime<Utc>,
    pub content_type: Option<String>,
    pub metadata: BTreeMap<String, String>,
    pub parts: BTreeMap<u32, UploadPart>,
}

impl MultipartUpload {
    pub fn new(bucket: String, key: String, owner_id: String) -> Self {
        Self {
            upload_id: Uuid::new_v4().to_string(),
            bucket,
            key,
            owner_id,
            created_at: Utc::now(),
            content_type: None,
            metadata: BTreeMap::new(),
            parts: BTreeMap::new(),
        }
    }

    pub fn add_part(&mut self, part: UploadPart) {
        self.parts.insert(part.part_number, part);
    }

    pub fn sorted_parts(&self) -> Vec<&UploadPart> {
        self.parts.values().collect()
    }

    pub fn total_size(&self) -> u64 {
        self.parts.values().map(|p| p.size).sum()
    }
}

/// An uploaded part
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct UploadPart {
    pub part_number: u32,
    pub etag: String,
    pub size: u64,
    pub cid: String,
    pub uploaded_at: DateTime<Utc>,
    pub checksum_blake3: Option<String>,
}

impl UploadPart {
    pub fn new(part_number: u32, etag: String, size: u64, cid: String) -> Self {
        Self {
            part_number,
            etag,
            size,
            cid,
            uploaded_at: Utc::now(),
            checksum_blake3: None,
        }
    }
}

/// Manager for multipart uploads
pub struct MultipartManager {
    uploads: DashMap<String, MultipartUpload>,
    expiry_secs: u64,
}

impl MultipartManager {
    pub fn new(expiry_secs: u64) -> Self {
        Self {
            uploads: DashMap::new(),
            expiry_secs,
        }
    }

    pub fn create_upload_with_metadata(
        &self,
        bucket: String,
        key: String,
        owner_id: String,
        content_type: Option<String>,
        metadata: BTreeMap<String, String>,
    ) -> MultipartUpload {
        let mut upload = MultipartUpload::new(bucket, key, owner_id);
        upload.content_type = content_type;
        upload.metadata = metadata;
        debug!(upload_id = %upload.upload_id, bucket = %upload.bucket, key = %upload.key, "Creating multipart upload");
        self.uploads.insert(upload.upload_id.clone(), upload.clone());
        upload
    }

    pub fn get_upload(&self, upload_id: &str) -> Option<MultipartUpload> {
        self.uploads.get(upload_id).map(|r| r.clone())
    }

    pub fn add_part(&self, upload_id: &str, part: UploadPart) -> Option<()> {
        debug!(upload_id = %upload_id, part_number = part.part_number, "Adding part to upload");
        let result = self.uploads.get_mut(upload_id).map(|mut upload| {
            upload.add_part(part);
        });
        if result.is_none() {
            warn!(upload_id = %upload_id, "Upload not found when adding part");
        }
        result
    }

    pub fn complete_upload(&self, upload_id: &str) -> Option<MultipartUpload> {
        debug!(upload_id = %upload_id, "Completing multipart upload");
        self.uploads.remove(upload_id).map(|(_, upload)| upload)
    }

    pub fn abort_upload(&self, upload_id: &str) -> Option<MultipartUpload> {
        self.uploads.remove(upload_id).map(|(_, upload)| upload)
    }

    pub fn list_uploads(&self, bucket: &str) -> Vec<MultipartUpload> {
        self.uploads
            .iter()
            .filter(|r| r.bucket == bucket)
            .map(|r| r.clone())
            .collect()
    }

    pub fn list_parts(&self, upload_id: &str) -> Option<Vec<UploadPart>> {
        self.uploads.get(upload_id).map(|upload| {
            upload.sorted_parts().into_iter().cloned().collect()
        })
    }

    pub fn cleanup_expired(&self) -> usize {
        let expiry_threshold = Utc::now() - Duration::seconds(self.expiry_secs as i64);
        let expired: Vec<_> = self.uploads
            .iter()
            .filter(|r| r.created_at < expiry_threshold)
            .map(|r| r.upload_id.clone())
            .collect();
        let count = expired.len();
        for id in expired {
            self.uploads.remove(&id);
        }
        count
    }
}
