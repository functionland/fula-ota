#!/bin/bash

# At the beginning of your script
trap 'cleanup; exit' SIGINT SIGTERM EXIT

HOME_DIR=/home/pi
FULA_PATH=/usr/bin/fula
FULA_LOG_PATH=$HOME_DIR/fula.sh.log
ACTIVE_PLUGINS_FILE="${HOME_DIR}/.internal/active-plugins.txt"
UPDATE_PLUGIN_FILE="${HOME_DIR}/.internal/update-plugins.txt"
PLUGINS_DIR="${FULA_PATH}/plugins"
LOCKFILE="/tmp/plugin_manager.lock"
SEMAPHORE="/tmp/plugin_semaphore"



# Function to log messages
log_message() {
    echo "$(date): $1" | sudo tee -a $FULA_LOG_PATH
}

acquire_lock() {
    exec 200>"$LOCKFILE"
    flock -n 200 || return 1
}

release_lock() {
    flock -u 200 2>/dev/null
    exec 200>&- 2>/dev/null
}

# Function to wait for fula_fxsupport container to start
wait_for_fula_fxsupport() {
    local attempt=0
    while ! sudo docker ps --format '{{.Names}}' | grep -q '^fula_fxsupport$'; do
        
        attempt=$((attempt + 1))
        log_message "Waiting for fula_fxsupport container to start... (Attempt $attempt)"
        sleep 10
    done
}

# Function to copy plugins from docker
copy_plugins_from_docker() {
    log_message "Copying plugins from fula_fxsupport container..."
    sudo docker cp fula_fxsupport:/linux/plugins/. ${PLUGINS_DIR} 2>&1 | sudo tee -a $FULA_LOG_PATH
    sync
    sleep 2
}

write_plugin_status() {
    local plugin=$1
    local status=$2
    local status_file="$PLUGINS_DIR/$plugin/status.txt"

    # Ensure the plugin directory exists
    mkdir -p "$(dirname "$status_file")"

    # Write the status to the file, overwriting any existing content
    echo -n "$status" > "$status_file"

    # Log the status update
    log_message "Updated status for $plugin: $status"
}

# Function to add plugin to active plugins file
add_to_active_plugins() {
    local plugin=$1
    echo "$plugin" | sudo tee -a "$ACTIVE_PLUGINS_FILE" > /dev/null
    log_message "Added $plugin to active plugins file"
}

# Function to remove plugin from active plugins file
remove_from_active_plugins() {
    local plugin=$1
    local temp_file
    temp_file=$(mktemp)
    grep -v "^$plugin$" "$ACTIVE_PLUGINS_FILE" > "$temp_file"
    sudo mv "$temp_file" "$ACTIVE_PLUGINS_FILE"
    log_message "Removed $plugin from active plugins file"
}

# Function to process a single plugin
process_plugin() {
    local plugin=$1
    local action=$2
    local plugin_dir="$PLUGINS_DIR/$plugin"
    local timeout=300  # 5 minutes timeout

    (
        flock -x -w $timeout 201 || { log_message "Failed to acquire lock for $plugin"; return 1; }
        if [ "$action" == "install" ]; then
            if [ -f "$plugin_dir/install.sh" ]; then
                log_message "Running install.sh for $plugin"
                
                write_plugin_status "$plugin" "Installing"
                (
                    set -o pipefail
                    if timeout $timeout sudo bash "$plugin_dir/install.sh" 2>&1 | sudo tee -a $FULA_LOG_PATH; then
                        log_message "install.sh completed successfully for $plugin"
                        
                        write_plugin_status "$plugin" "Installed"
                        if [ -f "$plugin_dir/start.sh" ]; then
                            log_message "Running start.sh for $plugin"
                            
                            if timeout $timeout sudo bash "$plugin_dir/start.sh" 2>&1 | sudo tee -a $FULA_LOG_PATH; then
                                log_message "start.sh completed successfully for $plugin"
                                
                            else
                                log_message "start.sh failed for $plugin"
                                remove_from_active_plugins "$plugin"
                                
                                return 1
                            fi
                        else
                            log_message "start.sh not found for $plugin"
                            
                        fi
                    else
                        log_message "install.sh failed for $plugin. Removing from active plugins."
                        remove_from_active_plugins "$plugin"
                        
                        return 1
                    fi
                )
                install_exit_status=$?
                if [ $install_exit_status -ne 0 ]; then
                    log_message "Installation process failed for $plugin with exit status $install_exit_status"
                    remove_from_active_plugins "$plugin"
                    
                    return 1
                fi
            else
                log_message "install.sh not found for $plugin. Removing from active plugins."
                remove_from_active_plugins "$plugin"
                
                return 1
            fi
        elif [ "$action" == "uninstall" ]; then
            if [ -f "$plugin_dir/stop.sh" ]; then
                log_message "Running stop.sh for $plugin"
                (
                    set -o pipefail
                    if ! timeout $timeout sudo bash "$plugin_dir/stop.sh" 2>&1 | sudo tee -a $FULA_LOG_PATH; then
                        log_message "stop.sh failed for $plugin"
                        
                    fi
                )
            else
                log_message "stop.sh not found for $plugin"
            fi
            if [ -f "$plugin_dir/uninstall.sh" ]; then
                log_message "Running uninstall.sh for $plugin"
                
                (
                    set -o pipefail
                    if timeout $timeout sudo bash "$plugin_dir/uninstall.sh" 2>&1 | sudo tee -a $FULA_LOG_PATH; then
                        log_message "uninstall.sh completed successfully for $plugin"
                        remove_from_active_plugins "$plugin"
                        
                    else
                        log_message "uninstall.sh failed for $plugin. Adding back to active plugins."
                        add_to_active_plugins "$plugin"
                        
                        return 1
                    fi
                )
                uninstall_exit_status=$?
                if [ $uninstall_exit_status -ne 0 ]; then
                    log_message "Uninstallation process failed for $plugin with exit status $uninstall_exit_status"
                    add_to_active_plugins "$plugin"
                    
                    return 1
                fi
            else
                log_message "uninstall.sh not found for $plugin"
                remove_from_active_plugins "$plugin"
                
            fi
        fi
        sync
        sleep 1
    ) 201>$SEMAPHORE
    
    local exit_status=$?
    if [ $exit_status -ne 0 ]; then
        log_message "Error processing plugin $plugin (action: $action). Exit status: $exit_status"
        
    fi
    return $exit_status
}

process_active_plugins_changes() {
    local old_plugins=("$@")
    local new_plugins

    if [ ! -s "$ACTIVE_PLUGINS_FILE" ]; then
        new_plugins=()
    else
        mapfile -t new_plugins < "$ACTIVE_PLUGINS_FILE"
    fi

    for plugin in "${new_plugins[@]}"; do
        
        if ! printf '%s\n' "${old_plugins[@]}" | grep -q "^$plugin$"; then
            log_message "New plugin detected: $plugin"
            if ! process_plugin "$plugin" "install"; then
                log_message "Failed to install plugin: $plugin"
            fi
            sync
            sleep 1
        fi
    done

    for plugin in "${old_plugins[@]}"; do
        
        if ! printf '%s\n' "${new_plugins[@]}" | grep -q "^$plugin$"; then
            log_message "Plugin removed: $plugin"
            if ! process_plugin "$plugin" "uninstall"; then
                log_message "Failed to uninstall plugin: $plugin"
            fi
            sync
            sleep 1
        fi
    done
}

# Function to install all active plugins
install_active_plugins() {
    
    local plugins
    if [ ! -s "$ACTIVE_PLUGINS_FILE" ]; then
        plugins=()
    else
        mapfile -t plugins < "$ACTIVE_PLUGINS_FILE"
    fi
    for plugin in "${plugins[@]}"; do
        log_message "Installing active plugin: $plugin"
        process_plugin "$plugin" "install"
        sync
        sleep 2
    done
}

update_plugin() {
    local plugin=$1
    local plugin_dir="$PLUGINS_DIR/$plugin"
    

    if [ -f "$plugin_dir/update.sh" ]; then
        log_message "Running update.sh for $plugin"
        if timeout $timeout sudo bash "$plugin_dir/update.sh" 2>&1 | sudo tee -a $FULA_LOG_PATH; then
            log_message "update.sh completed successfully for $plugin"
        else
            log_message "update.sh failed for $plugin"
        fi
    else
        log_message "update.sh not found for $plugin"
    fi
}
process_plugin_updates() {
    local plugins_to_update=()
    mapfile -t plugins_to_update < "$UPDATE_PLUGIN_FILE"
    
    for plugin in "${plugins_to_update[@]}"; do
        update_plugin "$plugin"
    done
    
    # Empty the file after processing all updates
    : > "$UPDATE_PLUGIN_FILE"
}

# Cleanup function
cleanup() {
    log_message "Cleaning up..."
    running=false
    jobs -p | xargs -r kill
    release_lock
    rm -f $LOCKFILE $SEMAPHORE
    log_message "Cleanup complete"
}

# Set trap for cleanup
trap cleanup EXIT INT TERM

# Main execution
acquire_lock

wait_for_fula_fxsupport
sync
sleep 2
copy_plugins_from_docker
sync
sleep 2

# Install all active plugins
install_active_plugins
sync
sleep 2

# Initial read of active plugins
if [ ! -s "$ACTIVE_PLUGINS_FILE" ]; then
    old_plugins=()
else
    mapfile -t old_plugins < "$ACTIVE_PLUGINS_FILE"
fi

release_lock

# Before the main loop
running=true

# Main loop
while $running; do
    
    if ! inotifywait -q -e modify -t 5 "$ACTIVE_PLUGINS_FILE" "$UPDATE_PLUGIN_FILE"; then
        # Timeout occurred, continue the loop
        
        continue
    fi
    
    if ! acquire_lock; then
        log_message "Failed to acquire lock. Skipping this iteration."
        continue
    fi
    
    if [ -s "$UPDATE_PLUGIN_FILE" ]; then
        log_message "Changes detected in update-plugins.txt"
        process_plugin_updates
    fi
    
    if [ -s "$ACTIVE_PLUGINS_FILE" ]; then
        log_message "Changes detected in active-plugins.txt"
        process_active_plugins_changes "${old_plugins[@]}"
        
        if [ ! -s "$ACTIVE_PLUGINS_FILE" ]; then
            old_plugins=()
        else
            mapfile -t old_plugins < "$ACTIVE_PLUGINS_FILE"
        fi
    fi
    
    release_lock
    
    log_message "Finished processing changes"
done