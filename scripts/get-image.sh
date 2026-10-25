#!/usr/bin/env bash
# usage: scripts/get-image.sh [path]
set -euo pipefail

IMAGE_PATH="${1:-/var/lib/libvirt/images/noble-base.img}"
IMAGE_URL="${IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"

if [ -f "$IMAGE_PATH" ]; then
  echo "Image already exists: $IMAGE_PATH"
  exit 0
fi

echo "Downloading $IMAGE_URL -> $IMAGE_PATH"
sudo wget -q --show-progress -O "$IMAGE_PATH.part" "$IMAGE_URL"
sudo mv "$IMAGE_PATH.part" "$IMAGE_PATH"
