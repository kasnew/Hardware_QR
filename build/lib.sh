#!/bin/bash
# Shared helpers for ISO build scripts.

resolve_docker() {
    if docker info >/dev/null 2>&1; then
        DOCKER="docker"
        return 0
    fi

    if command -v sudo >/dev/null 2>&1 && sudo -n docker info >/dev/null 2>&1; then
        echo "Docker requires sudo. Prefixing docker commands with sudo..."
        DOCKER="sudo docker"
        return 0
    fi

    if command -v systemctl >/dev/null 2>&1 && ! systemctl is-active --quiet docker; then
        echo "Docker daemon is not running."
        if command -v sudo >/dev/null 2>&1 && sudo -n systemctl start docker >/dev/null 2>&1; then
            echo "Docker started successfully."
            if docker info >/dev/null 2>&1; then
                DOCKER="docker"
                return 0
            fi
            if sudo -n docker info >/dev/null 2>&1; then
                DOCKER="sudo docker"
                return 0
            fi
        fi
    fi

    echo "Docker is not accessible from this user."
    echo "Start Docker and either add this user to the docker group or run this script with sudo."
    return 1
}

extract_iso_from_image() {
    local image="$1"
    local out_dir="$2"
    local dest_iso="$3"

    mkdir -p "$out_dir"
    local container_id
    container_id=$($DOCKER create "$image")
    $DOCKER cp "${container_id}:/out/." "$out_dir/"
    $DOCKER rm "$container_id"

    local iso_file
    iso_file=$(find "$out_dir" -maxdepth 1 -type f -name '*.iso' | head -n 1)
    if [ -z "$iso_file" ]; then
        echo "Error: no ISO file found in build output."
        return 1
    fi

    mv -f "$iso_file" "$dest_iso"
    rm -rf "$out_dir"
}
