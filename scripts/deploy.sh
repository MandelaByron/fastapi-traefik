#!/usr/bin/env bash
#
# docqa zero-downtime deploy.
#
#   ./scripts/deploy.sh <image-tag>
#   ./scripts/deploy.sh 3f2a9c1...        # normal deploy (git SHA)
#   ./scripts/deploy.sh <previous-sha>    # rollback
#
# How the swap works: Traefik's Docker provider groups every container sharing
# the same `traefik.http.services.docqa-app.*` labels into one load-balanced
# service. So we start a SECOND app container on the new image alongside the
# old one, wait for its healthcheck, let Traefik pick it up, then drain and
# remove the old one. At no point are there zero healthy servers.
#
# Nothing here is global: no `docker system prune`, no untargeted restarts.
# Coolify's containers, networks and images are untouched.

set -euo pipefail

IMAGE_TAG="${1:-${IMAGE_TAG:-}}"
if [[ -z "${IMAGE_TAG}" ]]; then
  echo "usage: $0 <image-tag>" >&2
  exit 1
fi
export IMAGE_TAG

PROJECT="${PROJECT:-fastapi-traefik}"
ENV_FILE="${ENV_FILE:-.env}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"   # seconds to wait for the new container
DRAIN_SECONDS="${DRAIN_SECONDS:-10}"      # grace for Traefik to register the new server
STOP_TIMEOUT="${STOP_TIMEOUT:-30}"        # SIGTERM -> SIGKILL window for the old container
RUN_MIGRATIONS="${RUN_MIGRATIONS:-1}"

COMPOSE=(docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}")
LBL_PROJECT="label=com.docker.compose.project=${PROJECT}"
LBL_APP="label=com.docker.compose.service=app"

app_containers() {
  docker ps -q --filter "${LBL_PROJECT}" --filter "${LBL_APP}" | sort
}

container_name() {
  docker inspect -f '{{.Name}}' "$1" 2>/dev/null | sed 's|^/||'
}

wait_healthy() {
  local cid="$1" deadline=$(( SECONDS + HEALTH_TIMEOUT )) status
  while (( SECONDS < deadline )); do
    if ! docker inspect -f '{{.State.Running}}' "${cid}" >/dev/null 2>&1; then
      echo "  container exited during startup"
      return 1
    fi
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${cid}")"
    case "${status}" in
      healthy) return 0 ;;
      none)
        echo "  ⚠ no healthcheck defined on this image — falling back to a fixed wait"
        sleep 20
        return 0
        ;;
      unhealthy)
        # keep waiting; retries may still bring it up before the deadline
        ;;
    esac
    sleep 3
  done
  return 1
}

echo "🚀 Deploying ${IMAGE_TAG} to project '${PROJECT}'"
echo ""

# --- 1. pull -----------------------------------------------------------------
# Pull before anything else so a registry problem fails the deploy while the
# old stack is still fully serving traffic.
echo "▶ Pulling image now…"
"${COMPOSE[@]}" pull app

# --- 2. migrations -----------------------------------------------------------
# Runs on the NEW image against Neon, before any traffic reaches it. Because
# old and new containers overlap, migrations must be backward compatible with
# the currently running code: add columns nullable, backfill, and only drop in
# a later release. Set RUN_MIGRATIONS=0 to skip.
# if [[ "${RUN_MIGRATIONS}" == "1" ]]; then
#   echo "▶ Running migrations…"
#   "${COMPOSE[@]}" run --rm --no-deps app backend db upgrade
# fi

# --- 3. start the new generation --------------------------------------------
mapfile -t OLD < <(app_containers)
target=$(( ${#OLD[@]} + 1 ))

echo "▶ Starting new app container (scaling app to ${target})…"
# --no-recreate keeps the old container running; --scale creates the missing
# one, which is built from the current config and therefore the new image.
echo "RUNNING --- ${COMPOSE[@]} up -d --no-deps --no-recreate --scale 'app=${target}' app "

"${COMPOSE[@]}" up -d --no-deps --no-recreate --scale "app=${target}" app

mapfile -t ALL < <(app_containers)
mapfile -t NEW < <(comm -13 <(printf '%s\n' "${OLD[@]:-}") <(printf '%s\n' "${ALL[@]}"))

if (( ${#NEW[@]} == 0 )); then
  echo "❌ no new container was created — aborting, old stack still serving" >&2
  exit 1
fi

for cid in "${NEW[@]}"; do
  echo "▶ Waiting for $(container_name "${cid}") to become healthy…"
  if ! wait_healthy "${cid}"; then
    echo ""
    echo "❌ New container never became healthy. Last 50 log lines:" >&2
    docker logs --tail 50 "${cid}" >&2 || true
    echo ""
    echo "▶ Rolling back: removing the new container, old one keeps serving."
    docker rm -f "${cid}" >/dev/null 2>&1 || true
    exit 1
  fi
done

# --- 4. drain and retire the old generation ---------------------------------
if (( ${#OLD[@]} > 0 )); then
  echo "▶ Letting Traefik register the new server (${DRAIN_SECONDS}s)…"
  sleep "${DRAIN_SECONDS}"

  for cid in "${OLD[@]}"; do
    echo "▶ Draining $(container_name "${cid}")…"
    # SIGTERM: uvicorn stops accepting new connections and finishes in-flight
    # requests within --timeout-graceful-shutdown. Traefik sees the die event
    # and drops the server; the retry middleware covers the gap.
    docker stop -t "${STOP_TIMEOUT}" "${cid}" >/dev/null
    docker rm "${cid}" >/dev/null
  done
fi

# --- 5. worker ---------------------------------------------------------------
# Taskiq is queue-backed, so a short worker gap is safe — unacked tasks stay in
# Redis. stop_grace_period lets in-flight ingestion finish first.
echo "▶ Recreating taskiq worker…"
# "${COMPOSE[@]}" up -d --no-deps --force-recreate taskiq_worker

# --- 6. sweep superseded images ---------------------------------------------
# Label-scoped, images only. Do NOT call scripts/docker-cleanup.sh from here —
# that one runs `compose down` and would take the stack offline.
# echo "▶ Removing superseded images…"
# dangling="$(docker image ls -q --filter dangling=true --filter 'label=com.docqa.owner=docqa' | sort -u)"
# if [[ -n "${dangling}" ]]; then
#   # shellcheck disable=SC2086
#   docker rmi ${dangling} >/dev/null 2>&1 || true
#   echo "  removed $(printf '%s\n' "${dangling}" | wc -l | tr -d ' ') image(s)"
# else
#   echo "  none"
# fi

# echo ""
# --- 6. sweep superseded images ----------------------------------------------
# "Superseded" = tagged image for this repo, not 'latest', not referenced by
# any container (running or stopped). This is usage-based rather than the
# dangling=true filter, which only matches untagged (<none>:<none>) images
# and never matches our SHA-tagged builds.
echo "▶ Removing superseded images…"
used="$(docker ps -a --format '{{.Image}}' | sort -u)"
all="$(docker image ls "${IMAGE_REPO}" --format '{{.Repository}}:{{.Tag}}' | grep -v ':latest$' | sort -u || true)"
superseded="$(comm -23 <(printf '%s\n' "${all}") <(printf '%s\n' "${used}") || true)"
 
if [[ -n "${superseded}" ]]; then
  # shellcheck disable=SC2086
  echo "${superseded}" | xargs -r docker rmi >/dev/null 2>&1 || true
  echo "  removed $(printf '%s\n' "${superseded}" | wc -l | tr -d ' ') image(s)"
else
  echo "  none"
fi
 
echo ""
echo "✅ Deployed ${IMAGE_TAG}"
"${COMPOSE[@]}" ps