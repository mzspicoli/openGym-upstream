#!/usr/bin/env bash
# Deploy of the VPS release (api + mcp + web), run on the server.
#
# This file is the trust boundary of the pipeline. Install it by hand at
# /srv/apps/deploy/deploy.sh (owned by the operator, NOT writable by the CI key) and let CI reach it
# only through an SSH key restricted in authorized_keys:
#
#   command="/srv/apps/deploy/deploy.sh",restrict ssh-ed25519 AAAA... opengym-ci
#
# so the CI job can run exactly this script and nothing else. The docker group is root-equivalent,
# which is why the script is never shipped by CI itself.
#
# Commands (the first word of SSH_ORIGINAL_COMMAND, or of the arguments):
#   deploy <tag>   read a tar stream on stdin (docker-compose.yml, docker-compose.vps.yml,
#                  images.tar.gz), load the images, back the data up, swap api -> mcp -> web and
#                  wait for each to be healthy. Any failure puts the previous images back.
#   rollback       put the previous images back (the ones recorded by the last deploy).
#   status         print what is running.
#
# Environment overrides exist for the tests (deploy/vps/test-deploy.sh) and never need setting in
# production: OG_ROOT, OG_DATA, OG_PROJECT, OG_HEALTH_URL, OG_MIN_FREE_MB, OG_HEALTH_WAIT, OG_DRY_RUN.
set -euo pipefail

ROOT=${OG_ROOT:-/srv/apps}
DATA=${OG_DATA:-/srv/data}
PROJECT=${OG_PROJECT:-opengym}
HEALTH_URL=${OG_HEALTH_URL:-http://127.0.0.1:8085/api/health}
MIN_FREE_MB=${OG_MIN_FREE_MB:-3000}
HEALTH_WAIT=${OG_HEALTH_WAIT:-180}
DRY_RUN=${OG_DRY_RUN:-0}

RELEASES=$ROOT/releases
BACKUPS=$ROOT/deploy-backups
STATE=$ROOT/deploy-state
LINK=$ROOT/opengym
SERVICES=(api mcp web)

log() { printf '[deploy %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ERRO: $*"; exit 1; }
run() { if [ "$DRY_RUN" = 1 ]; then log "(dry-run) $*"; else "$@"; fi; }

# docker compose against a release dir, with one image tag. The shell variable wins over the
# OPENGYM_IMAGE_TAG line of that release's .env, which is how each service keeps its own tag
# (the web image of a release can differ from its api and mcp ones).
dc() {
  local dir=$1 tag=$2
  shift 2
  ( cd "$dir" && OPENGYM_IMAGE_TAG="$tag" docker compose -p "$PROJECT" \
      -f docker-compose.yml -f docker-compose.vps.yml --profile mcp "$@" )
}

wait_healthy() {
  local c=$1 t=0 s
  while [ "$t" -lt "$HEALTH_WAIT" ]; do
    s=$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null || echo none)
    [ "$s" = healthy ] && return 0
    [ "$s" = unhealthy ] && return 1
    sleep 5
    t=$((t + 5))
  done
  return 1
}

image_tag_of() { docker inspect -f '{{.Config.Image}}' "$1" 2>/dev/null | sed 's/^.*://'; }

record_previous() {
  mkdir -p "$STATE"
  {
    echo "RELEASE_DIR=$(readlink -f "$LINK")"
    for s in "${SERVICES[@]}"; do echo "TAG_$s=$(image_tag_of "opengym-$s")"; done
  } > "$STATE/previous.env"
}

rollback_previous() {
  [ -f "$STATE/previous.env" ] || die "sem $STATE/previous.env: nada para restaurar"
  # shellcheck disable=SC1091
  . "$STATE/previous.env"
  [ -d "$RELEASE_DIR" ] || die "release anterior sumiu: $RELEASE_DIR"
  log "ROLLBACK para $RELEASE_DIR"
  local s tag
  for s in "${SERVICES[@]}"; do
    eval "tag=\${TAG_$s:-}"
    [ -n "$tag" ] || { log "sem tag anterior para $s, pulando"; continue; }
    run dc "$RELEASE_DIR" "$tag" up -d --no-build --no-deps "$s"
    [ "$DRY_RUN" = 1 ] || wait_healthy "opengym-$s" || log "AVISO: opengym-$s nao ficou saudavel apos o rollback"
  done
  [ "$DRY_RUN" = 1 ] || ln -sfn "$RELEASE_DIR" "$LINK"
}

cmd_status() {
  docker ps --format '{{.Names}} {{.Image}} {{.Status}}' | grep '^opengym-' || true
  readlink -f "$LINK" || true
}

cmd_deploy() {
  local tag=$1
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z._-]{0,40}$ ]] || die "tag invalida: $tag"

  mkdir -p "$STATE" "$BACKUPS" "$RELEASES"
  exec 9> "$STATE/deploy.lock"
  flock -n 9 || die "outro deploy esta em andamento"

  local free
  free=$(df -Pm "$ROOT" | awk 'NR==2{print $4}')
  [ "$free" -ge "$MIN_FREE_MB" ] || die "pouco espaco em disco: ${free} MB livres, minimo $MIN_FREE_MB"

  local staging
  staging=$(mktemp -d "$ROOT/deploy-staging.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -rf '$staging'" EXIT

  log "recebendo o pacote"
  tar -x --no-same-owner --no-same-permissions -C "$staging" -f -
  local f
  for f in docker-compose.yml docker-compose.vps.yml images.tar.gz; do
    [ -s "$staging/$f" ] || die "pacote sem $f"
  done
  local extra
  extra=$(ls -A "$staging" | grep -v -x -e docker-compose.yml -e docker-compose.vps.yml -e images.tar.gz || true)
  [ -z "$extra" ] || die "arquivos inesperados no pacote: $extra"

  local release=$RELEASES/opengym-$tag
  [ ! -e "$release" ] || die "release ja existe: $release"
  local current
  current=$(readlink -f "$LINK")
  [ -f "$current/.env" ] || die "sem .env no release atual ($current)"

  log "carregando as imagens"
  if [ "$DRY_RUN" != 1 ]; then
    gzip -dc "$staging/images.tar.gz" | docker load
  fi
  local s
  for s in "${SERVICES[@]}"; do
    [ "$DRY_RUN" = 1 ] || docker image inspect "opengym-vps/$s:$tag" > /dev/null || die "imagem opengym-vps/$s:$tag nao veio no pacote"
  done

  record_previous

  local bk=$BACKUPS/opengym-pre-$tag-$(date -u +%Y%m%d%H%M)
  log "backup dos dados em $bk"
  if [ "$DRY_RUN" != 1 ]; then
    mkdir -p "$bk"
    docker run --rm -v "$DATA":/d:ro -v "$bk":/b alpine \
      sh -c 'tar czf /b/data.tgz -C /d opengym opengym-mcp-remote'
    [ -s "$bk/data.tgz" ] || die "backup vazio"
  fi

  log "montando $release"
  mkdir -p "$release/coach-auth"
  cp "$staging/docker-compose.yml" "$staging/docker-compose.vps.yml" "$release/"
  { grep -v '^OPENGYM_IMAGE_TAG=' "$current/.env" || true; echo "OPENGYM_IMAGE_TAG=$tag"; } > "$release/.env.new"
  mv "$release/.env.new" "$release/.env"
  chmod 600 "$release/.env"
  run dc "$release" "$tag" config -q

  for s in "${SERVICES[@]}"; do
    log "trocando $s"
    run dc "$release" "$tag" up -d --no-build --no-deps "$s"
    if [ "$DRY_RUN" != 1 ] && ! wait_healthy "opengym-$s"; then
      log "opengym-$s nao ficou saudavel"
      rollback_previous
      die "deploy $tag falhou em $s; voltou ao release anterior"
    fi
  done

  if [ "$DRY_RUN" != 1 ] && ! curl -fsS -m 10 "$HEALTH_URL" > /dev/null; then
    rollback_previous
    die "health check final falhou; voltou ao release anterior"
  fi

  [ "$DRY_RUN" = 1 ] || ln -sfn "$release" "$LINK"
  log "OK: $tag no ar. Release anterior: $current. Backup: $bk"
  log "para voltar: ssh <host> rollback"
}

read -r cmd arg _ <<< "${SSH_ORIGINAL_COMMAND:-$*}"
case "${cmd:-}" in
  deploy)   [ -n "${arg:-}" ] || die "uso: deploy <tag>"; cmd_deploy "$arg" ;;
  rollback) rollback_previous ;;
  status)   cmd_status ;;
  *)        die "comando desconhecido: ${cmd:-<vazio>} (use deploy <tag>, rollback ou status)" ;;
esac
