//! Application state and CID file watcher

use crate::config::LocalGatewayConfig;
use crate::multipart_manager::MultipartManager;
use fula_blockstore::{FlexibleBlockStore, IpfsPinningBlockStore, IpfsPinningConfig};
use fula_core::BucketManager;
use std::sync::Arc;
use tracing::{info, warn, error};

/// Hash a user ID for privacy using BLAKE3 with domain separation.
/// Matches the cloud gateway's hash_user_id() from fula-cli/state.rs.
pub fn hash_user_id(user_id: &str) -> String {
    let mut hasher = blake3::Hasher::new();
    hasher.update(b"fula:user_id:");
    hasher.update(user_id.as_bytes());
    let hash = hasher.finalize();
    hex::encode(&hash.as_bytes()[..16])
}

/// Application state shared across handlers
pub struct AppState {
    /// Gateway configuration
    pub config: LocalGatewayConfig,
    /// Block store (IPFS or memory fallback)
    pub block_store: Arc<FlexibleBlockStore>,
    /// Bucket manager
    pub bucket_manager: Arc<BucketManager<FlexibleBlockStore>>,
    /// Multipart upload manager
    pub multipart_manager: Arc<MultipartManager>,
}

impl AppState {
    /// Create a new application state
    pub async fn new(config: LocalGatewayConfig) -> anyhow::Result<Self> {
        // Wait for IPFS to become available — kubo-local may still be initializing
        // its repo/config. We poll until the connection succeeds rather than falling
        // back to in-memory storage, which would lose data.
        let store = Self::wait_for_ipfs(&config).await;
        let block_store = Arc::new(FlexibleBlockStore::IpfsPinning(store));
        info!("Storage mode: IPFS (persistent)");

        // Initialize bucket manager with persistence
        let bucket_manager = if let Some(ref registry_path) = config.registry_cid_path {
            info!("Bucket registry persistence enabled at: {}", registry_path);
            Arc::new(BucketManager::with_persistence(
                Arc::clone(&block_store),
                registry_path,
            ))
        } else {
            Arc::new(BucketManager::new(Arc::clone(&block_store)))
        };

        // Load existing bucket registry
        match bucket_manager.load_registry().await {
            Ok(count) if count > 0 => {
                info!("Loaded {} bucket(s) from persistent registry", count);
            }
            Ok(_) => {
                info!("Starting with empty bucket registry");
            }
            Err(e) => {
                return Err(anyhow::anyhow!(
                    "Failed to load bucket registry: {}. \
                     Refusing to start to prevent data loss. \
                     Ensure IPFS is running and the registry block is available.",
                    e
                ));
            }
        }

        let multipart_manager = Arc::new(MultipartManager::new(config.multipart_expiry_secs));

        let state = Self {
            config,
            block_store,
            bucket_manager,
            multipart_manager,
        };

        Ok(state)
    }

    async fn create_ipfs_store(config: &LocalGatewayConfig) -> anyhow::Result<IpfsPinningBlockStore> {
        let ipfs_config = IpfsPinningConfig::with_ipfs(&config.ipfs_url);
        let store = IpfsPinningBlockStore::new(ipfs_config).await?;
        Ok(store)
    }

    /// Wait indefinitely for IPFS to become available, retrying every 5 seconds.
    /// kubo-local may be running but still initializing its repo — the API on
    /// port 5002 won't respond until that's done. We must not fall back to
    /// in-memory storage because that loses data.
    async fn wait_for_ipfs(config: &LocalGatewayConfig) -> IpfsPinningBlockStore {
        let mut attempt = 0u64;
        loop {
            attempt += 1;
            match Self::create_ipfs_store(config).await {
                Ok(store) => {
                    info!("Connected to IPFS at {} (attempt {})", config.ipfs_url, attempt);
                    return store;
                }
                Err(e) => {
                    // Log every attempt for the first 5, then every ~60s (12 * 5s) to avoid spam
                    if attempt <= 5 || attempt % 12 == 0 {
                        warn!(
                            "Waiting for IPFS at {} (attempt {}, error: {}), retrying in 5s...",
                            config.ipfs_url, attempt, e
                        );
                    }
                }
            }
            tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        }
    }
}

/// Spawn a background task that polls the registry CID file every 30s.
/// When the CID changes (written by fula-pinning), reload the bucket registry.
pub fn spawn_cid_watcher(
    bucket_manager: Arc<BucketManager<FlexibleBlockStore>>,
    cid_path: String,
) {
    tokio::spawn(async move {
        let mut last_cid = read_cid_file(&cid_path);
        loop {
            tokio::time::sleep(std::time::Duration::from_secs(30)).await;
            let current_cid = read_cid_file(&cid_path);
            if current_cid != last_cid {
                info!(
                    old = ?last_cid,
                    new = ?current_cid,
                    "Registry CID changed, reloading"
                );
                match bucket_manager.load_registry().await {
                    Ok(count) => {
                        info!("Reloaded {} bucket(s) from registry", count);
                        // Re-read CID file to capture any change during async load
                        last_cid = read_cid_file(&cid_path);
                    }
                    Err(e) => {
                        error!("Failed to reload registry: {}", e);
                        // Keep last_cid unchanged so next poll retries
                    }
                }
            }
        }
    });
}

fn read_cid_file(path: &str) -> Option<String> {
    std::fs::read_to_string(path)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// Local session injected into request extensions by auth middleware
#[derive(Clone, Debug)]
pub struct LocalSession {
    /// BLAKE3-hashed user ID for storage scoping
    pub hashed_user_id: String,
    /// Display name
    pub display_name: String,
}

#[allow(dead_code)]
impl LocalSession {
    pub fn can_read(&self) -> bool {
        true
    }

    pub fn can_write(&self) -> bool {
        true
    }
}
