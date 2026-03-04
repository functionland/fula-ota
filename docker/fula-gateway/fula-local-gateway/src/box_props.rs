//! Reads box_props.json for owner filtering and pairing secret authentication.
//!
//! box_props.json contains:
//! - `auto_pin_token`: JWT token whose `sub` claim identifies the paired user
//! - `auto_pin_pairing_secret`: static bearer secret for local device auth

use tracing::{info, warn};

/// Read box_props.json and extract owner_filter (BLAKE3-hashed JWT sub) and bearer_secret.
///
/// Returns (owner_filter, bearer_secret).
pub fn read_box_props(path: &str) -> (Option<String>, Option<String>) {
    let data = match std::fs::read_to_string(path) {
        Ok(d) => d,
        Err(e) => {
            warn!(path = %path, error = %e, "Cannot read box_props.json");
            return (None, None);
        }
    };

    let props: serde_json::Value = match serde_json::from_str(&data) {
        Ok(v) => v,
        Err(e) => {
            warn!(path = %path, error = %e, "Cannot parse box_props.json");
            return (None, None);
        }
    };

    let bearer_secret = props
        .get("auto_pin_pairing_secret")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string());

    let owner_filter = props
        .get("auto_pin_token")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .and_then(|jwt| extract_owner_id_from_jwt(jwt));

    (owner_filter, bearer_secret)
}

/// Decode JWT payload (no validation -- we just need the `sub` claim)
/// and compute BLAKE3 hash matching the gateway's `hash_user_id()`.
fn extract_owner_id_from_jwt(jwt: &str) -> Option<String> {
    let parts: Vec<&str> = jwt.split('.').collect();
    if parts.len() < 2 {
        warn!("Invalid JWT format in box_props.json");
        return None;
    }

    use base64::engine::{Engine, general_purpose::URL_SAFE_NO_PAD};
    let payload_bytes = match URL_SAFE_NO_PAD.decode(parts[1]) {
        Ok(b) => b,
        Err(e) => {
            warn!(error = %e, "Failed to decode JWT payload from box_props.json");
            return None;
        }
    };

    let payload: serde_json::Value = match serde_json::from_slice(&payload_bytes) {
        Ok(v) => v,
        Err(e) => {
            warn!(error = %e, "Failed to parse JWT payload from box_props.json");
            return None;
        }
    };

    let sub = payload.get("sub").and_then(|v| v.as_str())?;

    let hashed = crate::state::hash_user_id(sub);
    info!(sub = %sub, hashed_owner_id = %hashed, "Derived owner_id from box_props.json JWT");
    Some(hashed)
}
