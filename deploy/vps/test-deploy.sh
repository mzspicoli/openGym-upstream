#!/usr/bin/env bash
# Tests for deploy.sh with a fake docker, curl and flock: no container, no network and nothing
# outside a temp dir is touched. Run on Linux (the server's OS):  bash deploy/vps/test-deploy.sh
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=$HERE/deploy.sh
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

new_env() {
  T=$(mktemp -d)
  mkdir -p "$T/root/releases/opengym-v1.4.3-old" "$T/bin" "$T/data"
  printf 'RP_ID=x\nOPENGYM_IMAGE_TAG=v1.4.3-old\nORIGIN=https://x\n' > "$T/root/releases/opengym-v1.4.3-old/.env"
  : > "$T/root/releases/opengym-v1.4.3-old/docker-compose.yml"
  : > "$T/root/releases/opengym-v1.4.3-old/docker-compose.vps.yml"
  ln -s "$T/root/releases/opengym-v1.4.3-old" "$T/root/opengym"
  : > "$T/calls.log"
  cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$FAKE_LOG"
case "$1" in
  inspect)
    last=${@: -1}
    if [[ "$*" == *Config.Image* ]]; then echo "opengym-vps/${last#opengym-}:v1.4.3-old"
    else
      svc=${last#opengym-}
      if [ "${FAKE_UNHEALTHY:-}" = "$svc" ] && [ ! -f "$FAKE_LOG.rolled" ]; then echo unhealthy; else echo healthy; fi
    fi ;;
  image) exit 0 ;;
  load) cat > /dev/null ;;
  volume|network|rm|logs) exit 0 ;;
  exec)
    if [[ "$*" == *wget* ]]; then
      if [ -n "${FAKE_REHEARSAL_FAIL:-}" ] && [[ "$*" == *ogrehearse-api* ]]; then echo '{"ok":true,"users":1,"writable":true}'
      else echo '{"ok":true,"users":2,"writable":true}'; fi
    elif [[ "$*" == *node* ]]; then
      [ -z "${FAKE_PARSE_FAIL:-}" ] || exit 1
      echo "perfis lidos: 2"
    fi ;;
  run)
    for a in "$@"; do case "$a" in *:/b) d=${a%:/b}; mkdir -p "$d"; echo data > "$d/data.tgz" ;; esac; done ;;
  compose)
    case "$*" in *" up "*) case "$(pwd)" in *opengym-v1.4.3-old) : > "$FAKE_LOG.rolled" ;; esac ;; esac
    echo "  tag=$OPENGYM_IMAGE_TAG dir=$(pwd)" >> "$FAKE_LOG" ;;
esac
exit 0
EOF
  printf '#!/usr/bin/env bash\n[ -z "${FAKE_CURL_FAIL:-}" ]\n' > "$T/bin/curl"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/flock"
  chmod +x "$T/bin/"*
}

bundle() { # a tar stream like the CI sends
  local d; d=$(mktemp -d)
  echo 'services: {}' > "$d/docker-compose.yml"; echo 'services: {}' > "$d/docker-compose.vps.yml"; echo images | gzip -c > "$d/images.tar.gz"
  [ -z "${1:-}" ] || : > "$d/$1"
  tar -cf - -C "$d" .
  rm -rf "$d"
}

run_deploy() { # $1 = command line, stdin = tar
  PATH="$T/bin:$PATH" FAKE_LOG="$T/calls.log" OG_ROOT="$T/root" OG_DATA="$T/data" \
    OG_MIN_FREE_MB=1 OG_HEALTH_WAIT=1 SSH_ORIGINAL_COMMAND="$1" bash "$SCRIPT" 2>&1
}

# 1. a bad tag and an unknown command are refused before anything runs
new_env
out=$(bundle | run_deploy "deploy ../../etc"); rc=$?
{ [ $rc -ne 0 ] && grep -q "tag invalida" <<< "$out" && ! grep -q "^docker" "$T/calls.log"; } && ok "tag invalida recusada" || bad "tag invalida recusada: $out"
out=$(bundle | run_deploy "rm -rf /"); rc=$?
{ [ $rc -ne 0 ] && grep -q "comando desconhecido" <<< "$out"; } && ok "comando desconhecido recusado" || bad "comando desconhecido recusado: $out"
rm -rf "$T"

# 2. an unexpected file in the package is refused
new_env
out=$(bundle evil.sh | run_deploy "deploy v1.4.4-abc1234"); rc=$?
{ [ $rc -ne 0 ] && grep -q "inesperados" <<< "$out" && ! grep -q "compose.*up" "$T/calls.log"; } && ok "pacote com arquivo extra recusado" || bad "pacote com arquivo extra recusado: $out"
rm -rf "$T"

# 3. happy path: backup, release created, api -> mcp -> web, symlink moved, .env tag updated
new_env
out=$(bundle | run_deploy "deploy v1.4.4-abc1234"); rc=$?
[ $rc -eq 0 ] && ok "deploy feliz termina com 0" || bad "deploy feliz termina com 0: $out"
order=$(grep -E "^docker compose .* up " "$T/calls.log" | sed -E 's/.* --no-deps ([a-z]+).*/\1/' | tr '\n' ' ')
[ "$order" = "api mcp web " ] && ok "ordem api, mcp, web" || bad "ordem api, mcp, web: '$order'"
[ "$(readlink "$T/root/opengym")" = "$T/root/releases/opengym-v1.4.4-abc1234" ] && ok "link aponta para o release novo" || bad "link aponta para o release novo"
grep -q '^OPENGYM_IMAGE_TAG=v1.4.4-abc1234$' "$T/root/releases/opengym-v1.4.4-abc1234/.env" && grep -q '^RP_ID=x$' "$T/root/releases/opengym-v1.4.4-abc1234/.env" && ok ".env copiado com a tag nova" || bad ".env copiado com a tag nova"
ls "$T"/root/deploy-backups/*/data.tgz > /dev/null 2>&1 && ok "backup dos dados criado" || bad "backup dos dados criado"
grep -q '^TAG_web=v1.4.3-old$' "$T/root/deploy-state/previous.env" && ok "tags anteriores registradas" || bad "tags anteriores registradas"
rm -rf "$T"

# 4. a service that never gets healthy rolls everything back and keeps the old link
new_env
out=$(FAKE_UNHEALTHY=mcp bundle | FAKE_UNHEALTHY=mcp run_deploy "deploy v1.4.4-abc1234"); rc=$?
{ [ $rc -ne 0 ] && grep -q "ROLLBACK" <<< "$out"; } && ok "falha em mcp aciona rollback" || bad "falha em mcp aciona rollback: $out"
[ "$(readlink "$T/root/opengym")" = "$T/root/releases/opengym-v1.4.3-old" ] && ok "link continua no release anterior" || bad "link continua no release anterior"
grep -q "tag=v1.4.3-old dir=$T/root/releases/opengym-v1.4.3-old" "$T/calls.log" && ok "imagens anteriores restauradas" || bad "imagens anteriores restauradas"
rm -rf "$T"

# 5. the same tag cannot be deployed twice
new_env
bundle | run_deploy "deploy v1.4.4-abc1234" > /dev/null
out=$(bundle | run_deploy "deploy v1.4.4-abc1234"); rc=$?
{ [ $rc -ne 0 ] && grep -q "ja existe" <<< "$out"; } && ok "release repetido recusado" || bad "release repetido recusado: $out"
rm -rf "$T"

# 6. a failing final health check also rolls back
new_env
out=$(bundle | FAKE_CURL_FAIL=1 run_deploy "deploy v1.4.4-abc1234"); rc=$?
{ [ $rc -ne 0 ] && grep -q "health check final falhou" <<< "$out"; } && ok "health final falho aciona rollback" || bad "health final falho aciona rollback: $out"
rm -rf "$T"

# 7. the rehearsal on a copy of the data runs after the backup and before the first real swap
new_env
bundle | run_deploy "deploy v1.4.4-abc1234" > /dev/null
r=$(grep -n "docker run -d --name ogrehearse-api" "$T/calls.log" | head -1 | cut -d: -f1)
u=$(grep -n "^docker compose .* up " "$T/calls.log" | head -1 | cut -d: -f1)
b=$(grep -n "docker run --rm .*alpine sh -c tar czf" "$T/calls.log" | head -1 | cut -d: -f1)
{ [ -n "$r" ] && [ -n "$u" ] && [ -n "$b" ] && [ "$b" -lt "$r" ] && [ "$r" -lt "$u" ]; } && ok "ensaio roda depois do backup e antes da primeira troca" || bad "ordem backup < ensaio < troca (b=$b r=$r u=$u)"
grep -q "docker rm -f ogrehearse-api" "$T/calls.log" && grep -q "docker network rm ogrehearse" "$T/calls.log" && grep -q "docker volume rm ogrehearse" "$T/calls.log" && ok "ensaio limpa container, rede e volume" || bad "ensaio limpa container, rede e volume"
rm -rf "$T"

# 8. a rehearsal that reads fewer profiles than production stops everything before any swap
new_env
out=$(bundle | FAKE_REHEARSAL_FAIL=1 run_deploy "deploy v1.4.4-abc1234"); rc=$?
{ [ $rc -ne 0 ] && grep -q "ensaio na copia dos dados falhou" <<< "$out" && ! grep -q "^docker compose .* up " "$T/calls.log"; } && ok "ensaio reprovado nao troca nada" || bad "ensaio reprovado nao troca nada: $out"
[ "$(readlink "$T/root/opengym")" = "$T/root/releases/opengym-v1.4.3-old" ] && [ ! -e "$T/root/releases/opengym-v1.4.4-abc1234" ] && ok "ensaio reprovado: link e releases intactos" || bad "ensaio reprovado: link e releases intactos"
grep -q "docker rm -f ogrehearse-api" "$T/calls.log" && ok "ensaio reprovado tambem limpa o que criou" || bad "ensaio reprovado tambem limpa o que criou"
rm -rf "$T"

# 9. an unreadable state file in the copy stops the deploy too
new_env
out=$(bundle | FAKE_PARSE_FAIL=1 run_deploy "deploy v1.4.4-abc1234"); rc=$?
{ [ $rc -ne 0 ] && grep -q "ilegivel" <<< "$out" && ! grep -q "^docker compose .* up " "$T/calls.log"; } && ok "estado ilegivel na copia aborta o deploy" || bad "estado ilegivel na copia aborta o deploy: $out"
rm -rf "$T"

[ $fail -eq 0 ] && echo "todos os testes passaram" || { echo "HA FALHAS"; exit 1; }
