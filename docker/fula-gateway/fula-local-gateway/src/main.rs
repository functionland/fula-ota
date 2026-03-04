//! Fula Local Gateway - S3-compatible gateway for FxBlox devices
//!
//! This binary runs on local FxBlox hardware. It uses fula-core and fula-blockstore
//! as shared libraries from fula-api, but has its own simplified auth (bearer-only),
//! no rate limiting, no admin API, and no cloud pinning.

#[allow(dead_code)]
mod auth;
mod box_props;
mod config;
#[allow(dead_code)]
mod error;
mod handlers;
#[allow(dead_code)]
mod multipart_manager;
mod routes;
#[allow(dead_code)]
mod server;
mod state;
#[allow(dead_code)]
mod xml;

use clap::Parser;
use config::LocalGatewayConfig;
use tracing::info;

/// Fula Local S3 Gateway for FxBlox devices
#[derive(Parser, Debug)]
#[command(name = "fula-gateway", version, about)]
struct Args {
    /// Host to bind to
    #[arg(long, env = "FULA_HOST", default_value = "0.0.0.0")]
    host: String,

    /// Port to listen on
    #[arg(long, env = "FULA_PORT", default_value_t = 9000)]
    port: u16,

    /// IPFS API URL (kubo)
    #[arg(long, env = "IPFS_API_URL", default_value = "http://127.0.0.1:5001")]
    ipfs_url: String,

    /// Path for bucket registry CID persistence
    #[arg(long, env = "REGISTRY_CID_PATH")]
    registry_cid_path: Option<String>,

    /// Path to box_props.json
    #[arg(long, env = "BOX_PROPS_FILE")]
    box_props_file: Option<String>,

    /// Override owner ID (BLAKE3-hashed user ID)
    #[arg(long, env = "OWNER_ID")]
    owner_id: Option<String>,

    /// Override bearer secret for authentication
    #[arg(long, env = "BEARER_SECRET")]
    bearer_secret: Option<String>,

    /// Maximum body size in bytes
    #[arg(long, env = "MAX_BODY_SIZE", default_value_t = 5 * 1024 * 1024 * 1024)]
    max_body_size: usize,

    /// Enable debug logging
    #[arg(long, env = "DEBUG")]
    debug: bool,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = Args::parse();

    // Initialize tracing
    let log_filter = if args.debug {
        "debug,hyper=info,h2=info"
    } else {
        "info"
    };
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new(log_filter)),
        )
        .init();

    // Read box_props.json for owner_id and bearer_secret
    let (box_owner_id, box_bearer_secret) = match &args.box_props_file {
        Some(path) => {
            info!(path = %path, "Reading box_props.json");
            box_props::read_box_props(path)
        }
        None => (None, None),
    };

    // CLI args override box_props values
    let owner_id = args.owner_id.or(box_owner_id);
    let bearer_secret = args.bearer_secret.or(box_bearer_secret);

    if owner_id.is_some() {
        info!("Owner filtering enabled");
    }
    if bearer_secret.is_some() {
        info!("Bearer authentication enabled");
    } else {
        info!("No bearer secret configured (unpaired mode, auth disabled)");
    }

    let config = LocalGatewayConfig {
        host: args.host,
        port: args.port,
        ipfs_url: args.ipfs_url,
        registry_cid_path: args.registry_cid_path,
        box_props_file: args.box_props_file,
        owner_id,
        bearer_secret,
        max_body_size: args.max_body_size,
        ..Default::default()
    };

    server::run_server(config).await
}
