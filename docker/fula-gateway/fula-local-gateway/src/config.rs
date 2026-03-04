//! Local gateway configuration (no cloud fields)

/// Configuration for the local FxBlox S3 gateway
#[derive(Clone, Debug)]
pub struct LocalGatewayConfig {
    /// Host to bind to
    pub host: String,
    /// Port to listen on
    pub port: u16,
    /// IPFS API URL (kubo)
    pub ipfs_url: String,
    /// Path for bucket registry CID persistence
    pub registry_cid_path: Option<String>,
    /// Path to box_props.json for pairing config (stored for reference)
    #[allow(dead_code)]
    pub box_props_file: Option<String>,
    /// BLAKE3-hashed owner ID from box_props JWT sub claim
    pub owner_id: Option<String>,
    /// Bearer secret from box_props pairing secret
    pub bearer_secret: Option<String>,
    /// Maximum request body size (bytes)
    pub max_body_size: usize,
    /// Multipart upload expiry (seconds)
    pub multipart_expiry_secs: u64,
}

impl Default for LocalGatewayConfig {
    fn default() -> Self {
        Self {
            host: "0.0.0.0".to_string(),
            port: 9000,
            ipfs_url: "http://127.0.0.1:5001".to_string(),
            registry_cid_path: Some("/internal/fula-gateway/registry.cid".to_string()),
            box_props_file: Some("/internal/box_props.json".to_string()),
            owner_id: None,
            bearer_secret: None,
            max_body_size: 5 * 1024 * 1024 * 1024, // 5 GB
            multipart_expiry_secs: 24 * 60 * 60,    // 24 hours
        }
    }
}

impl LocalGatewayConfig {
    /// Get the bind address
    pub fn bind_addr(&self) -> String {
        format!("{}:{}", self.host, self.port)
    }
}
