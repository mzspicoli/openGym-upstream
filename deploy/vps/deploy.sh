#!/usr/bin/env bash
# Deploy of the VPS release (api + mcp + web), run on the server.
#
# This file is the trust boundary of the pipeline. Install it by hand at
# /srv/apps/deploy/opengym-deploy.sh (owned by the operator, NOT writable by the CI key) and let CI reach it
# only through an SSH key restricted in authorized_keys:
#
#   command="/srv/apps/deploy/opengym-deploy.sh",restrict ssh-ed25519 AAAA... opengym-ci
#
# so the CI job can run exactly this script and nothing else. The docker group is root-equivalent,
# which is why the script is never shipped by CI itself.
#
# Commands (the first word of SSH_ORIGINAL_COMMAND, or of the arguments):
#   deploy <tag>   read a tar stream on stdin (docker-compose.yml, docker-compose.vps.yml,
#                  images.tar.gz), load the images, back the data up, REHEARSE the new api on a copy
#                  of that data (nothing real changes if it fails), then swap api -> mcp -> web and
#                  wait for each to be healthy. Any failure puts the previous images back.
#   rollback       put the previous images back (the ones recorded by the last deploy).
#   rehearse [tag] run the rehearsal on a fresh copy of the data against the running (or given) images;
#                  changes nothing in production.
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

# Rehearsal of the new version on a COPY of the real data, isolated from production (own network,
# own volume, nothing published). The api image is started on the data it is about to serve and has
# to come up healthy, report the same number of profiles as production and be able to read every
# state file. It is the gate before anything real is swapped: a failure here changes nothing.
rehearse() {
  local tag=$1 bk=$2
  local id=$$ net vol api prod_users new_health new_users
  net=ogrehearse-$id; vol=ogrehearse-data-$id; api=ogrehearse-api-$id
  rehearse_cleanup() {
    docker rm -f "$api" > /dev/null 2>&1 || true
    docker network rm "$net" > /dev/null 2>&1 || true
    docker volume rm "$vol" > /dev/null 2>&1 || true
  }
  log "ensaio: subindo a versao nova numa copia dos dados"
  docker network create "$net" > /dev/null || { rehearse_cleanup; return 1; }
  docker volume create "$vol" > /dev/null || { rehearse_cleanup; return 1; }
  docker run --rm -v "$vol":/d -v "$bk":/b:ro alpine sh -c 'tar xzf /b/data.tgz -C /d' \
    || { rehearse_cleanup; log "ensaio: nao consegui restaurar a copia"; return 1; }
  docker run -d --name "$api" --network "$net" -v "$vol":/x:ro -e PORT=3000 -e DATA_DIR=/data \
    -e RP_ID=rehearsal.invalid -e ORIGIN=https://rehearsal.invalid -e TRUST_PROXY=1 -e INVITE_ONLY=1 \
    "opengym-vps/api:$tag" sh -c 'cp -a /x/opengym/. /data/ && exec node server.js' > /dev/null \
    || { rehearse_cleanup; log "ensaio: a imagem nova nao iniciou"; return 1; }
  if ! wait_healthy "$api"; then
    log "ensaio: a versao nova nao ficou saudavel sobre os dados reais. Ultimas linhas:"
    docker logs --tail 15 "$api" 2>&1 | sed 's/^/    /' || true
    rehearse_cleanup; return 1
  fi
  new_health=$(docker exec "$api" wget -qO- -T 5 http://127.0.0.1:3000/api/health 2> /dev/null || true)
  prod_users=$(docker exec opengym-api wget -qO- -T 5 http://127.0.0.1:3000/api/health 2> /dev/null | sed -n 's/.*"users":\([0-9]*\).*/\1/p' || true)
  new_users=$(printf '%s' "$new_health" | sed -n 's/.*"users":\([0-9]*\).*/\1/p')
  if ! printf '%s' "$new_health" | grep -q '"ok":true' || [ -z "$new_users" ] || [ "$new_users" != "${prod_users:-x}" ]; then
    log "ensaio: health inesperado. copia=$new_health producao_users=${prod_users:-?}"
    rehearse_cleanup; return 1
  fi
  if ! docker exec "$api" node -e '
    const fs = require("fs"); let n = 0;
    JSON.parse(fs.readFileSync("/data/db.json", "utf8"));
    for (const f of fs.readdirSync("/data").filter(f => /^state-[^.]*\.json$/.test(f))) { JSON.parse(fs.readFileSync("/data/" + f, "utf8")); n++; }
    if (!n) { console.error("nenhum state-*.json"); process.exit(1); }
    console.log("perfis lidos: " + n);'; then
    log "ensaio: a copia tem arquivo de estado ilegivel"
    rehearse_cleanup; return 1
  fi
  rehearse_cleanup
  log "ensaio ok: a versao nova le todos os perfis ($new_users) e fica saudavel na copia dos dados"
}

cmd_status() {
  docker ps --format '{{.Names}} {{.Image}} {{.Status}}' | grep '^opengym-' || true
  readlink -f "$LINK" || true
}

cmd_rehearse() {
  # Same rehearsal as in a deploy, against the images that are running now (or a given tag), with a
  # fresh copy of the data. Changes nothing in production: use it to check the gate itself.
  local tag=${1:-$(image_tag_of opengym-api)}
  [ -n "$tag" ] || die "nao achei a tag da api em execucao"
  mkdir -p "$BACKUPS"
  local tmp
  tmp=$(mktemp -d "$BACKUPS/rehearsal-copy.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT
  docker run --rm -v "$DATA":/d:ro -v "$tmp":/b alpine sh -c 'tar czf /b/data.tgz -C /d opengym opengym-mcp-remote'
  [ -s "$tmp/data.tgz" ] || die "copia vazia"
  rehearse "$tag" "$tmp" || die "ensaio falhou"
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
    rehearse "$tag" "$bk" || die "ensaio na copia dos dados falhou; a producao nao foi tocada (imagens carregadas, nada trocado)"
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
  rehearse) cmd_rehearse "${arg:-}" ;;
  status)   cmd_status ;;
  *)        die "comando desconhecido: ${cmd:-<vazio>} (use deploy <tag>, rollback, rehearse ou status)" ;;
esac
