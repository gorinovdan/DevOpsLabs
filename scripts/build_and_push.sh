#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 3 ]]; then
  echo "Usage: $0 <image_prefix> [tag] [platform]"
  echo "Example (native): $0 ttl.sh/flowboard 24h"
  echo "Example (amd64): $0 ttl.sh/flowboard 24h linux/amd64"
  exit 1
fi

IMAGE_PREFIX="$1"
TAG="${2:-latest}"
PLATFORM="${3:-}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"

BACKEND_IMAGE="${IMAGE_PREFIX}-backend:${TAG}"
FRONTEND_IMAGE="${IMAGE_PREFIX}-frontend:${TAG}"

image_exists_remote() {
  local image="$1"
  docker manifest inspect "$image" >/dev/null 2>&1
}

build_and_push() {
  local image="$1"
  local context="$2"

  if [[ "$FORCE_REBUILD" != "1" ]] && image_exists_remote "$image"; then
    echo "Image already exists in registry, skipping build/push: ${image}"
    return 0
  fi

  if [[ -n "$PLATFORM" ]]; then
    if ! docker buildx version >/dev/null 2>&1; then
      echo "Error: docker buildx is required when platform is set (${PLATFORM})."
      exit 1
    fi
    echo "Building and pushing image (${PLATFORM}): ${image}"
    docker buildx build --platform "${PLATFORM}" --push -t "${image}" "${context}"
  else
    echo "Building image: ${image}"
    docker build -t "${image}" "${context}"

    echo "Pushing image: ${image}"
    docker push "${image}"
  fi
}

build_and_push "${BACKEND_IMAGE}" "./backend"
build_and_push "${FRONTEND_IMAGE}" "./frontend"

echo ""
echo "Published images:"
echo "  backend_image: ${BACKEND_IMAGE}"
echo "  frontend_image: ${FRONTEND_IMAGE}"
