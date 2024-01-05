#!/bin/bash

# Script to safely check and repair external drives' partitions

# Define services
services=("fula" "uniondrive")

# Logging function
log() {
    echo "$(date +"%Y-%m-%d %H:%M:%S"): $1"
}

# Check and repair filesystem function
check_repair_fs() {
    local device=$1
    local fstype=$2

    log "Checking and repairing filesystem of type $fstype on $device"

    case $fstype in
        vfat)
            sudo dosfsck -w -r -l -a -v -t $device || log "dosfsck failed on $device"
            ;;
        ntfs)
            sudo ntfsfix $device || log "ntfsfix failed on $device"
            ;;
        ext4)
            sudo e2fsck -p -f $device || log "e2fsck failed on $device"
            ;;
        *)
            log "Filesystem type $fstype not supported for auto-repair on $device"
            ;;
    esac
}

# Stop services
stop_services() {
    for service in "${services[@]}"; do
        log "Stopping $service service"
        sudo systemctl stop $service || log "Failed to stop $service"
    done
}

# Start services
start_services() {
    for service in "${services[@]}"; do
        log "Starting $service service"
        sudo systemctl start $service || log "Failed to start $service"
    done
}

# Main script logic
main() {
    # Ensure the script is run as root
    if [ "$(id -u)" -ne 0 ]; then
        log "This script must be run as root!"
        exit 1
    fi

    # Determine connected external storage devices' partitions
    for dev in /dev/sd?[0-9]; do

        # Determine the file system type
        fstype=$(sudo blkid -o value -s TYPE $dev)

        if [[ -n $fstype ]]; then
            log "Partition: $dev, Filesystem: $fstype"

            # Stop services
            stop_services

            # Unmount device if mounted
            mountpoint=$(mount | grep $dev | awk '{ print $3 }')
            if [[ -n $mountpoint ]]; then
                log "Unmounting $dev"
                sudo umount $dev || log "Failed to unmount $dev"
            fi

            # Check and repair filesystem
            check_repair_fs $dev $fstype

            # Start services
            start_services
        else
            log "No filesystem detected for $dev or device is not an external storage partition"
        fi
    done
}

# Run main script
main "$@"
