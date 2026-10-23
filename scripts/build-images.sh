#!/usr/bin/env bash
set -euo pipefail

# Build all project Docker images and tag them with the last commit hash.
# This is the documented manual escape hatch for when CI is unavailable.
#
# Usage:
#   scripts/build-images.sh            # uses last commit short hash
#   scripts/build-images.sh v1.2.3     # or specify an explicit tag
#
# Env:
#   IMAGE_PREFIX   Registry/namespace prefix (default: ghcr.io/mariusgeorgescu — images.yml's GHCR_OWNER)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# TD-01. This script builds from the WORKING TREE, so whatever sits in config/ goes into the build
# context — which is how a local build came to bake the live provider config into four images while
# ADR 0002 claimed the opposite. The exclusion lives in .dockerignore; this asserts it is still
# there, because a deleted line in that file is silent and the leak it causes is not recoverable
# once an image is pushed.
for secret in config/config_atlas.json config/config_palmares_validators.json; do
  if ! grep -qxF "${secret}" "${ROOT_DIR}/.dockerignore"; then
    echo "REFUSING TO BUILD: .dockerignore does not exclude ${secret}." >&2
    echo "Without that line the build context carries it and every image bakes it in." >&2
    exit 1
  fi
done

TAG="${1:-}"
if [[ -z "${TAG}" ]]; then
  TAG="$(git -C "${ROOT_DIR}" rev-parse --short HEAD)"
fi

IMAGE_PREFIX="${IMAGE_PREFIX:-ghcr.io/mariusgeorgescu}"
SERVICES=(admin query-api interaction-api attest-sync)

echo "Building images with tag: ${TAG}"
echo "Image prefix: ${IMAGE_PREFIX}"

PUSH="${PUSH:-false}"
if [[ "${PUSH}" == "true" ]]; then
  echo "ERROR: PUSH=true is not supported with the local shared base image 'palmares-builder'." >&2
  echo "Publish a multi-arch builder image and repoint the Dockerfiles at it" >&2
  echo "(e.g. ${IMAGE_PREFIX}/palmares-builder:9.6.6), or run with PUSH=false." >&2
  exit 1
fi

# Load only the host architecture into the local docker daemon
ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64|amd64) NATIVE_PLATFORM="linux/amd64" ;;
  arm64|aarch64) NATIVE_PLATFORM="linux/arm64" ;;
  *) echo "Unsupported host arch: ${ARCH}" >&2; exit 1 ;;
esac
BUILDX_FLAGS=(--platform "${NATIVE_PLATFORM}" --load)
echo "Local mode: building for ${NATIVE_PLATFORM} and loading locally"

cd "${ROOT_DIR}"

# Shared builder base (toolchain + cached deps; stable across source changes)
BUILDER_VERSION="9.6.6"
echo "Building shared builder base: palmares-builder:${BUILDER_VERSION}"
docker buildx build \
  "${BUILDX_FLAGS[@]}" \
  -f Dockerfile.base \
  -t "palmares-builder:${BUILDER_VERSION}" \
  .

# Shared runtime base (crypto libs; stable unless versions change)
RUNTIME_TAG="3.20"
echo "Building shared runtime base: palmares-runtime-base:${RUNTIME_TAG}"
docker buildx build \
  "${BUILDX_FLAGS[@]}" \
  -f Dockerfile.runtime-base \
  -t "palmares-runtime-base:${RUNTIME_TAG}" \
  .

for svc in "${SERVICES[@]}"; do
  echo "Building ${svc}"
  docker buildx build \
    "${BUILDX_FLAGS[@]}" \
    -f "Dockerfile.${svc}" \
    -t "${IMAGE_PREFIX}/palmares-${svc}:${TAG}" \
    .
done

printf '\nBuilt images:\n'
for svc in "${SERVICES[@]}"; do
  echo "  ${IMAGE_PREFIX}/palmares-${svc}:${TAG}"
done
