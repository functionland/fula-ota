//! Server startup and lifecycle

use crate::{state::AppState, config::LocalGatewayConfig, routes};
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::net::TcpListener;
use tracing::info;

/// Run the local gateway server
pub async fn run_server(config: LocalGatewayConfig) -> anyhow::Result<()> {
    let state = Arc::new(AppState::new(config.clone()).await?);

    // Spawn CID file watcher if registry path is configured
    if let Some(ref cid_path) = config.registry_cid_path {
        crate::state::spawn_cid_watcher(
            Arc::clone(&state.bucket_manager),
            cid_path.clone(),
        );
    }

    let app = routes::create_router(state);
    let addr = config.bind_addr();
    let listener = TcpListener::bind(&addr).await?;

    info!("Fula Local Gateway listening on http://{}", addr);

    axum::serve(listener, app.into_make_service_with_connect_info::<SocketAddr>()).await?;

    Ok(())
}

/// Run server with graceful shutdown
pub async fn run_server_with_shutdown(
    config: LocalGatewayConfig,
    shutdown_signal: impl std::future::Future<Output = ()> + Send + 'static,
) -> anyhow::Result<()> {
    let state = Arc::new(AppState::new(config.clone()).await?);

    if let Some(ref cid_path) = config.registry_cid_path {
        crate::state::spawn_cid_watcher(
            Arc::clone(&state.bucket_manager),
            cid_path.clone(),
        );
    }

    let app = routes::create_router(state);
    let addr = config.bind_addr();
    let listener = TcpListener::bind(&addr).await?;

    info!("Fula Local Gateway listening on http://{}", addr);

    axum::serve(listener, app.into_make_service_with_connect_info::<SocketAddr>())
        .with_graceful_shutdown(shutdown_signal)
        .await?;

    info!("Gateway shutdown complete");
    Ok(())
}
