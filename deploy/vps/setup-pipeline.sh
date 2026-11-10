#!/usr/bin/env bash
# One guided run that connects the GitHub fork to the VPS: checks the restricted CI key, pins the
# server host key, enables Actions, creates the `production` environment (you as reviewer, only
# vps/main and vps-v* tags allowed), stores the six secrets, and optionally runs the first deploy and
# approves it. The two things only you can do (the Tailscale admin pages) are walked through.
#
#   bash deploy/vps/setup-pipeline.sh --check     read-only: checks everything, changes nothing
#   bash deploy/vps/setup-pipeline.sh             the full guided setup
#
# Needs: gh, ssh, git, python3 (all on a Mac with the developer tools). Secrets are read from files or
# hidden prompts and piped to gh; they are never printed or written anywhere else.
set -uo pipefail

REPO=${OG_REPO:-mzspicoli/openGym-upstream}
WORKFLOW=vps-deploy.yml
REF=vps/main
ENVNAME=production
KEY=${OG_CI_KEY:-$HOME/.opengym-ci/opengym-ci}
VPS_SSH=${OG_VPS_SSH:-vps-kansas-city}   # your normal alias for the server
VPS_USER=${OG_VPS_USER:-matheus}
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m  %s\n' "$*"; }
warn() { printf '  \033[33m!!\033[0m  %s\n' "$*"; }
stop() { printf '\n\033[31mPAROU:\033[0m %s\n' "$*"; exit 1; }
pause() { [ "$CHECK_ONLY" = 1 ] && return 0; printf '\n  Pressione Enter quando terminar... '; read -r _; }
yesno() { [ "$CHECK_ONLY" = 1 ] && return 1; local a; printf '  %s [s/N] ' "$1"; read -r a; [ "$a" = s ] || [ "$a" = S ]; }

TMPCFG=""
cleanup() { [ -n "$TMPCFG" ] && rm -rf "$TMPCFG"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------------------------
say "1/6  Conferindo o que ja esta pronto"
for c in gh ssh git python3; do command -v "$c" > /dev/null || stop "falta o programa '$c'"; done
ok "programas necessarios instalados"

[ -f "$KEY" ] || stop "nao achei a chave do CI em $KEY (ela foi criada antes; veja o README)"
ok "chave do CI encontrada"

ci() { ssh -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=15 -o PreferredAuthentications=publickey "$VPS_USER@$VPS_SSH" "$@" < /dev/null; }
out=$(ci status 2>&1) || stop "a chave do CI nao conseguiu rodar 'status' na VPS: $out"
echo "$out" | grep -q opengym-api || stop "a VPS respondeu, mas sem o opengym-api: $out"
ok "a chave do CI roda o script de deploy na VPS (status ok)"
bad=$(ci 'ls /' 2>&1 || true)
echo "$bad" | grep -q "comando desconhecido" || stop "a chave do CI conseguiu rodar um comando qualquer. Nao continue. Resposta: $bad"
ok "e recusa qualquer outro comando (so o deploy.sh roda)"

HOST_FQDN=$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$VPS_SSH" "tailscale status --self --json 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin)[\"Self\"][\"DNSName\"].rstrip(\".\"))'" 2>/dev/null || true)
TS_IP=$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$VPS_SSH" "tailscale ip -4 2>/dev/null | head -1" 2>/dev/null || true)
[ -n "$HOST_FQDN" ] || stop "nao consegui descobrir o nome da VPS no Tailscale"
ok "nome da VPS no Tailscale: $HOST_FQDN"

PUB=$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$VPS_SSH" 'cat /etc/ssh/ssh_host_ed25519_key.pub' 2>/dev/null | cut -d' ' -f1,2)
[ -n "$PUB" ] || stop "nao consegui ler a chave do servidor (host key) na VPS"
KNOWN_HOSTS_LINE="$HOST_FQDN $PUB"
ok "chave do servidor lida direto dele (sem confiar na primeira conexao)"

# GitHub access: use the current login if it can manage secrets, else sign in once in a temp config.
gh_probe() { gh api "repos/$REPO/actions/secrets/public-key" --jq .key_id > /dev/null 2>&1; }
if gh_probe; then
  ok "o gh ja tem permissao para gerenciar segredos em $REPO"
elif [ "$CHECK_ONLY" = 1 ]; then
  warn "o gh atual nao gerencia segredos em $REPO; no modo completo o script faz um login temporario no navegador"
else
  say "O login atual do gh nao tem permissao para segredos. Vamos fazer um login temporario."
  echo "  O navegador vai abrir; autorize o 'GitHub CLI'. Isso nao troca o seu login de sempre."
  TMPCFG=$(mktemp -d); export GH_CONFIG_DIR="$TMPCFG"
  gh auth login --hostname github.com --git-protocol https --web --scopes repo,workflow || stop "login no GitHub nao concluido"
  gh_probe || stop "mesmo com o login novo nao ha permissao para segredos em $REPO"
  ok "login temporario feito"
fi

if [ "$CHECK_ONLY" = 1 ]; then
  say "Modo --check: nada foi alterado."
  if r=$(gh api "repos/$REPO/actions/permissions" --jq '.enabled' 2>/dev/null); then ok "Actions ativado no fork: $r"; else warn "nao consegui ler se o Actions esta ativado"; fi
  if r=$(gh api "repos/$REPO/environments/$ENVNAME" --jq '.protection_rules | map(select(.type=="required_reviewers")) | length' 2>/dev/null); then ok "environment $ENVNAME existe (regras de aprovador: $r)"; else warn "environment $ENVNAME ainda nao existe (o setup completo cria)"; fi
  gh secret list -e "$ENVNAME" -R "$REPO" 2>/dev/null | awk '{print "  segredo cadastrado: "$1}' || true
  exit 0
fi

# ---------------------------------------------------------------------------------------------
say "2/6  Ativando o Actions e criando o environment 'production' no GitHub"
gh api -X PUT "repos/$REPO/actions/permissions" -F enabled=true -f allowed_actions=all > /dev/null || stop "nao consegui ativar o Actions"
ok "Actions ativado no fork"
UID_GH=$(gh api user --jq .id) || stop "nao consegui ler o seu usuario no GitHub"
printf '{"reviewers":[{"type":"User","id":%s}],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' "$UID_GH" \
  | gh api -X PUT "repos/$REPO/environments/$ENVNAME" --input - > /dev/null || stop "nao consegui criar o environment"
ok "environment '$ENVNAME' criado: so voce aprova"
gh api -X POST "repos/$REPO/environments/$ENVNAME/deployment-branch-policies" -f name="$REF" -f type=branch > /dev/null 2>&1 || true
gh api -X POST "repos/$REPO/environments/$ENVNAME/deployment-branch-policies" -f name='vps-v*' -f type=tag > /dev/null 2>&1 || true
ok "so a branch $REF e as tags vps-v* podem usar os segredos"

# ---------------------------------------------------------------------------------------------
say "3/6  Tailscale (a unica parte que precisa de voce no navegador)"
cat << EOF

  O GitHub vai entrar na sua rede Tailscale como um aparelho temporario com a etiqueta 'tag:ci'.
  Para isso voce faz duas coisas no site do Tailscale.

  A) Politica de acesso. Vou abrir a pagina e copiar um trecho para a sua area de transferencia.
     Cole o trecho DENTRO do bloco principal { ... }, junto das outras chaves como "acls" ou "grants".
     Se ja existir "tagOwners" ou "grants", acrescente so o item de dentro. O editor avisa se der erro.
     Clique em Save.
EOF
SNIPPET=$(printf '"tagOwners": { "tag:ci": ["autogroup:admin"] },\n"grants": [ { "src": ["tag:ci"], "dst": ["%s"], "ip": ["tcp:22"] } ],' "${TS_IP:-100.x.x.x}")
printf '%s\n' "$SNIPPET" | (command -v pbcopy > /dev/null && pbcopy || cat > /dev/null)
printf '\n  Trecho copiado (se o pbcopy existir):\n\n%s\n' "$SNIPPET" | sed 's/^/    /'
command -v open > /dev/null && open "https://login.tailscale.com/admin/acls/file"
pause

cat << 'EOF'

  B) Credencial do GitHub. Vou abrir a pagina de OAuth clients.
     Clique em "Generate OAuth client", marque APENAS o escopo "Auth Keys" com "Write",
     escolha a etiqueta tag:ci e clique em Generate. O Tailscale mostra um Client ID e um Client secret
     UMA vez so: deixe a pagina aberta.
EOF
command -v open > /dev/null && open "https://login.tailscale.com/admin/settings/oauth"
pause
printf '  Cole o Client ID (aparece na tela enquanto digita, nao e segredo): '; read -r TS_ID
printf '  Cole o Client secret (nao aparece na tela): '; read -r -s TS_SECRET; echo
[ -n "$TS_ID" ] && [ -n "$TS_SECRET" ] || stop "faltou o Client ID ou o secret"
case "$TS_SECRET" in tskey-client-*) ok "o secret tem o formato esperado";; *) warn "o secret nao comeca com tskey-client-; confira se copiou o certo";; esac

# ---------------------------------------------------------------------------------------------
say "4/6  Guardando os 6 segredos no environment '$ENVNAME'"
setsec() { printf '%s' "$2" | gh secret set "$1" -e "$ENVNAME" -R "$REPO" > /dev/null && ok "$1" || stop "falhou ao guardar $1"; }
setsec TS_OAUTH_CLIENT_ID "$TS_ID"
setsec TS_OAUTH_SECRET "$TS_SECRET"
unset TS_SECRET
gh secret set VPS_DEPLOY_SSH_KEY -e "$ENVNAME" -R "$REPO" < "$KEY" > /dev/null && ok "VPS_DEPLOY_SSH_KEY" || stop "falhou ao guardar a chave SSH"
setsec VPS_KNOWN_HOSTS "$KNOWN_HOSTS_LINE"
setsec VPS_HOST "$HOST_FQDN"
setsec VPS_USER "$VPS_USER"

# ---------------------------------------------------------------------------------------------
say "5/6  Primeiro deploy pelo pipeline"
cat << EOF

  O pipeline vai rodar os testes, construir as 3 imagens e esperar a sua aprovacao antes de mexer na
  VPS. Ao aprovar, a VPS faz backup, troca api -> mcp -> web e volta sozinha ao release anterior se
  algo falhar. O app fica alguns segundos fora do ar durante a troca de cada servico.
EOF
if ! yesno "Disparar o pipeline agora?"; then
  say "Tudo configurado. Para disparar depois, rode este script de novo (ele cria uma tag vps-v* nova) ou crie a tag pela API: veja o README."
  exit 0
fi
# A manual dispatch only finds a workflow that lives on the fork's default branch, and ours is on
# $REF. The workflow also runs on a vps-v* tag, which works from any branch: create one at $REF.
SHA=$(gh api "repos/$REPO/branches/$REF" --jq .commit.sha) || stop "nao achei a branch $REF no fork"
VER=$(gh api "repos/$REPO/contents/frontend/package.json?ref=$SHA" --jq .content | base64 -d | python3 -c 'import sys,json; print(json.load(sys.stdin)["version"])') || stop "nao consegui ler a versao do app"
n=1
while gh api "repos/$REPO/git/ref/tags/vps-v$VER-$n" > /dev/null 2>&1; do n=$((n + 1)); done
TAG=vps-v$VER-$n
gh api -X POST "repos/$REPO/git/refs" -f ref="refs/tags/$TAG" -f sha="$SHA" > /dev/null || stop "nao consegui criar a tag $TAG"
ok "tag $TAG criada em ${SHA:0:9}; isso dispara o pipeline"
RUN_ID=""
n=0
while [ $n -lt 12 ] && [ -z "$RUN_ID" ]; do
  sleep 5; n=$((n + 1))
  RUN_ID=$(gh api "repos/$REPO/actions/runs?event=push&per_page=10" --jq ".workflow_runs[] | select(.head_branch==\"$TAG\" and .name==\"VPS deploy\") | .id" | head -1)
done
[ -n "$RUN_ID" ] || stop "nao achei a execucao que a tag disparou; veja https://github.com/$REPO/actions"
ok "execucao $RUN_ID: https://github.com/$REPO/actions/runs/$RUN_ID"
echo "  Esperando testes e build (uns 10 a 20 minutos)..."
n=0
while [ $n -lt 200 ]; do
  st=$(gh run view "$RUN_ID" -R "$REPO" --json status,conclusion --jq '.status+" "+(.conclusion//"")')
  case "$st" in completed*) break;; esac
  pend=$(gh api "repos/$REPO/actions/runs/$RUN_ID/pending_deployments" --jq '.[0].environment.id // empty' 2>/dev/null || true)
  [ -n "$pend" ] && break
  sleep 15; n=$((n + 1))
done
[ -n "${pend:-}" ] || case "$st" in completed*) ;; *) stop "demorou demais esperando a aprovacao; veja https://github.com/$REPO/actions/runs/$RUN_ID";; esac
case "$st" in completed*)
  warn "a execucao terminou antes de chegar na aprovacao: $st"
  gh run view "$RUN_ID" -R "$REPO" --log-failed 2>/dev/null | tail -40
  stop "o pipeline falhou antes do deploy (nada foi alterado na VPS). Me mande este trecho."
esac
say "6/6  Aprovacao"
ok "testes e build passaram; o deploy espera a sua aprovacao"
if yesno "Aprovar o deploy na VPS agora?"; then
  gh api -X POST "repos/$REPO/actions/runs/$RUN_ID/pending_deployments" -F "environment_ids[]=$pend" -f state=approved -f comment="aprovado pelo setup-pipeline.sh" > /dev/null \
    || stop "nao consegui aprovar; aprove em https://github.com/$REPO/actions/runs/$RUN_ID"
  ok "aprovado; acompanhando"
  gh run watch "$RUN_ID" -R "$REPO" --exit-status && ok "deploy concluido" || { gh run view "$RUN_ID" -R "$REPO" --log-failed 2>/dev/null | tail -40; stop "o deploy falhou (a VPS volta sozinha ao release anterior). Me mande este trecho."; }
  say "Estado final na VPS:"; ci status
else
  echo "  Sem problema. Aprove quando quiser em https://github.com/$REPO/actions/runs/$RUN_ID"
fi

say "Pronto. Falta so um cuidado de seguranca:"
echo "  - Revogue o token temporario de antes em https://github.com/settings/tokens"
echo "  - e apague a entrada do Keychain:  security delete-generic-password -s opengym-gh-public-repo"
echo "  - A chave privada do CI continua em $KEY; ela ja esta no GitHub. Voce pode apagar a copia local."
