#!/bin/bash

set -eo pipefail

df -h

BTRFS_TARGET_DIR="${BTRFS_TARGET_DIR:-$(
    dir=$(podman system info --format '{{.Store.GraphRoot}}' | sed 's|/storage$||')
    mkdir -p "$dir"
    echo "$dir"
)}"

BTRFS_MOUNT_OPTS=${BTRFS_MOUNT_OPTS:-"compress-force=zstd:2"}

BTRFS_LOOPBACK_FILE=${BTRFS_LOOPBACK_FILE:-/mnt/btrfs_loopbacks/$(systemd-escape -p "$BTRFS_TARGET_DIR")}
BTRFS_LOOPBACK_FREE=${BTRFS_LOOPBACK_FREE:-"0.8"}

btrfs_pdir="$(dirname "$BTRFS_LOOPBACK_FILE")"

sudo apt-get install -y btrfs-progs

MIN_SPACE=$((60 * 1000 * 1000 * 1000))

USE_RAID0=false
if [ -d "/mnt" ]; then
    AVAILABLE=$(findmnt /mnt --bytes --df --json | jq -r '.filesystems[0].avail // 0')
    AVAILABLE_HUMAN=$(findmnt /mnt --df --json | jq -r '.filesystems[0].avail // "0B"')

    if [[ "$AVAILABLE" -ge "$MIN_SPACE" ]]; then
        USE_RAID0=true
    fi
fi

if [ "$USE_RAID0" = true ]; then
    BTRFS_LOOPBACK_FILE2="/var/example.img"
    btrfs_pdir2="$(dirname "$BTRFS_LOOPBACK_FILE2")"

    sudo mkdir -p "$btrfs_pdir" && sudo chown "$(id -u)":"$(id -g)" "$btrfs_pdir"
    sudo mkdir -p "$btrfs_pdir2"

    _final_size1=$(findmnt --target "$btrfs_pdir" --bytes --df --json | jq -r --arg freeperc "$BTRFS_LOOPBACK_FREE" '.filesystems[0].avail * ($freeperc | tonumber) | round')
    _final_size2=$(findmnt --target "$btrfs_pdir2" --bytes --df --json | jq -r --arg freeperc "$BTRFS_LOOPBACK_FREE" '.filesystems[0].avail * ($freeperc | tonumber) | round')

    truncate -s "$_final_size1" "$BTRFS_LOOPBACK_FILE"
    sudo truncate -s "$_final_size2" "$BTRFS_LOOPBACK_FILE2"
    unset -v _final_size1 _final_size2

    LOOP_DEV_1=$(sudo losetup -fP --show "$BTRFS_LOOPBACK_FILE")
    LOOP_DEV_2=$(sudo losetup -fP --show "$BTRFS_LOOPBACK_FILE2")

    sudo mkfs.btrfs -f -d raid0 -m raid0 "$LOOP_DEV_1" "$LOOP_DEV_2"

    TEMP_MOUNT="/tmp/btrfs_pool_bootstrap"
    sudo mkdir -p "$TEMP_MOUNT"
    sudo mount "$LOOP_DEV_1" "$TEMP_MOUNT"
    sudo btrfs subvolume create "$TEMP_MOUNT/containers"
    sudo btrfs subvolume create "$TEMP_MOUNT/vartmp"
    sudo umount "$TEMP_MOUNT"
    sudo rmdir "$TEMP_MOUNT"

    sudo mkdir -p "$BTRFS_TARGET_DIR"
    sudo mkdir -p "/var/tmp"

    sudo mount -o "${BTRFS_MOUNT_OPTS},subvol=containers" "$LOOP_DEV_1" "$BTRFS_TARGET_DIR"
    sudo mount -o "${BTRFS_MOUNT_OPTS},subvol=vartmp" "$LOOP_DEV_1" "/var/tmp"
else
    AVAILABLE=$(findmnt / --bytes --df --json | jq -r '.filesystems[0].avail // 0')

    sudo mkdir -p "$btrfs_pdir" && sudo chown "$(id -u)":"$(id -g)" "$btrfs_pdir"
    _final_size=$(findmnt --target "$btrfs_pdir" --bytes --df --json | jq -r --arg freeperc "$BTRFS_LOOPBACK_FREE" '.filesystems[0].avail * ($freeperc | tonumber) | round')
    truncate -s "$_final_size" "$BTRFS_LOOPBACK_FILE"
    unset -v _final_size

    sudo mkfs.btrfs -f -r "$BTRFS_TARGET_DIR" "$BTRFS_LOOPBACK_FILE"
    sudo mount ${BTRFS_MOUNT_OPTS:+ -o "${BTRFS_MOUNT_OPTS}"} "$BTRFS_LOOPBACK_FILE" "$BTRFS_TARGET_DIR"
fi
