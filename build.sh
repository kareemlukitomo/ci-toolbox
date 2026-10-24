#!/usr/bin/env bash
# Build and publish the ci-toolbox image.
#
#   ./build.sh              # build, tag, then attempt the push
#   NO_PUSH=1 ./build.sh    # build and tag only
#   ENGINE=podman ./build.sh
#
# Tags: <git describe or date>-<short sha> and latest.
set -euo pipefail

cd "$(dirname "$0")"

REGISTRY="${REGISTRY:-registry.kareem.one}"
REPOSITORY="${REPOSITORY:-infra/ci-toolbox}"
IMAGE="${REGISTRY}/${REPOSITORY}"
NO_PUSH="${NO_PUSH:-0}"
PLATFORM="${PLATFORM:-linux/amd64}"

if [[ -n "${ENGINE:-}" ]]; then
  command -v "$ENGINE" >/dev/null || { echo "engine not found: $ENGINE" >&2; exit 1; }
else
  for candidate in docker podman buildah; do
    if command -v "$candidate" >/dev/null 2>&1; then
      ENGINE="$candidate"
      break
    fi
  done
fi
[[ -n "${ENGINE:-}" ]] || { echo "no docker, podman or buildah found" >&2; exit 1; }

short_sha="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
base_tag="$(git describe --tags --abbrev=0 2>/dev/null || date -u +%Y%m%d)"
tag="${base_tag}-${short_sha}"

echo "engine:  $ENGINE"
echo "image:   ${IMAGE}:${tag}"
echo "also:    ${IMAGE}:latest"

case "$ENGINE" in
  docker)
    docker build \
      --platform "$PLATFORM" \
      --build-arg "CI_TOOLBOX_REVISION=${short_sha}" \
      -f Containerfile \
      -t "${IMAGE}:${tag}" \
      -t "${IMAGE}:latest" \
      .
    ;;
  podman)
    podman build \
      --platform "$PLATFORM" \
      --build-arg "CI_TOOLBOX_REVISION=${short_sha}" \
      -f Containerfile \
      -t "${IMAGE}:${tag}" \
      -t "${IMAGE}:latest" \
      .
    ;;
  buildah)
    buildah bud \
      --platform "$PLATFORM" \
      --build-arg "CI_TOOLBOX_REVISION=${short_sha}" \
      -f Containerfile \
      -t "${IMAGE}:${tag}" \
      -t "${IMAGE}:latest" \
      .
    ;;
esac

if [[ "$ENGINE" == "buildah" ]]; then
  buildah inspect --format 'image id: {{.FromImageID}}' "${IMAGE}:${tag}" || true
else
  "$ENGINE" image inspect --format 'image id: {{.Id}}
size:     {{.Size}} bytes' "${IMAGE}:${tag}" || true
fi

echo "smoke test:"
"$ENGINE" run --rm "${IMAGE}:${tag}" trivy --version || true

if [[ "$NO_PUSH" == "1" ]]; then
  echo "NO_PUSH=1, skipping the push"
  exit 0
fi

# Reuse an existing credential file only. Never print a token and never prompt.
registry_host="${REGISTRY%%/*}"
login_added=0

have_ambient_auth() {
  [[ -f "${HOME}/.docker/config.json" ]] || return 1
  jq -e --arg h "$registry_host" '(.auths[$h] // .credHelpers[$h]) != null' \
    "${HOME}/.docker/config.json" >/dev/null 2>&1
}

if have_ambient_auth; then
  echo "using credentials already present in ${HOME}/.docker/config.json"
elif [[ -f /tmp/harbor-cfg.json ]]; then
  auth_b64="$(jq -r --arg h "$registry_host" '.auths[$h].auth // empty' /tmp/harbor-cfg.json)"
  if [[ -z "$auth_b64" ]]; then
    echo "no credential for ${registry_host} in /tmp/harbor-cfg.json" >&2
  else
    robot_user="$(printf '%s' "$auth_b64" | base64 -d | cut -d: -f1)"
    robot_pass="$(printf '%s' "$auth_b64" | base64 -d | cut -d: -f2-)"
    echo "logging in as ${robot_user} from /tmp/harbor-cfg.json"
    if printf '%s' "$robot_pass" | "$ENGINE" login "$registry_host" --username "$robot_user" --password-stdin >/dev/null 2>&1; then
      login_added=1
    else
      echo "login with the credential from /tmp/harbor-cfg.json failed" >&2
    fi
    unset robot_pass auth_b64
  fi
else
  echo "no credential file found, pushing anonymously" >&2
fi

push_log="$(mktemp)"
trap 'rm -f "$push_log"' EXIT

set +e
case "$ENGINE" in
  docker|podman) "$ENGINE" push "${IMAGE}:${tag}" 2>&1 | tee "$push_log"; status="${PIPESTATUS[0]}" ;;
  buildah) buildah push "${IMAGE}:${tag}" "docker://${IMAGE}:${tag}" 2>&1 | tee "$push_log"; status="${PIPESTATUS[0]}" ;;
esac
set -e

if [[ "$login_added" == "1" ]]; then
  "$ENGINE" logout "$registry_host" >/dev/null 2>&1 || true
fi

if [[ "$status" -ne 0 ]]; then
  if grep -Eqi '401|403|unauthorized|denied|authentication required|not found' "$push_log"; then
    echo "PUSH BLOCKED: the registry rejected the available credential." >&2
    reason="$(grep -Ei 'unauthorized|denied|401|403' "$push_log" | tail -1)"
    [[ -n "$reason" ]] || reason="$(tail -1 "$push_log")"
    echo "Reason: ${reason}" >&2
    echo "No robot account or Harbor configuration was changed." >&2
    exit 3
  fi
  echo "push failed with exit code ${status}" >&2
  exit "$status"
fi

case "$ENGINE" in
  docker|podman) "$ENGINE" push "${IMAGE}:latest" ;;
  buildah) buildah push "${IMAGE}:latest" "docker://${IMAGE}:latest" ;;
esac

echo "pushed ${IMAGE}:${tag} and ${IMAGE}:latest"
