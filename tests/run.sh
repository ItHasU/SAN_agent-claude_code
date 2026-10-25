#!/usr/bin/env bash
# Tests de bin/san, des hooks, de install.sh et du faux agent contre un mock server.
# shellcheck disable=SC2015  # idiome « test && ok || ko » volontaire
# Dépendances : bash, curl, python3 (stdlib). jq est utilisé s'il est présent
# (les tests d'install.sh en ont besoin ; ils sont ignorés sinon).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SAN="$ROOT/bin/san"
TMP="$(mktemp -d)"
TOKEN=agt_testtoken
pass=0 failn=0
SERVER_PID=""

cleanup() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
ko() { failn=$((failn + 1)); printf '  FAIL %s\n' "$1"; }
check() { # description commande...
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else ko "$d"; fi
}

# --- serveur mock ------------------------------------------------------------
LOG="$TMP/requests.jsonl"
python3 -I "$ROOT/tests/mock_server.py" --log "$LOG" --port-file "$TMP/port" --token "$TOKEN" &
SERVER_PID=$!
for _ in $(seq 1 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
[ -s "$TMP/port" ] || { echo "mock server non démarré"; exit 1; }
PORT="$(cat "$TMP/port")"
URL="http://127.0.0.1:$PORT"

export HOME="$TMP/home"; mkdir -p "$HOME"
unset SAN_URL SAN_TOKEN SAN_ENV_FILE SAN_STRICT SAN_DEBUG
export SAN_STATE_DIR="$TMP/state" SAN_HOOK_SYNC=1

reset_log() { : >"$LOG"; }
# req N EXPRESSION_PYTHON : évalue l'expression sur la N-ième requête (r), code 0 si vrai.
req() {
  python3 -I -c '
import json,sys
rs=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
n=int(sys.argv[2]); r=rs[n] if n<len(rs) else None
sys.exit(0 if r is not None and eval(sys.argv[3]) else 1)' "$LOG" "$1" "$2"
}
count() { grep -c . "$LOG" 2>/dev/null || true; }
configured() { SAN_URL="$URL" SAN_TOKEN="$TOKEN" "$@"; }

AUTH="r['headers'].get('authorization')=='Bearer $TOKEN'"

echo "== bin/san : sous-commandes"
reset_log
configured "$SAN" state working "Edit foo.ts" --progress 40 --ttl 900 >/dev/null
check "state: POST /api/v1/agent/state" req 0 "r['method']=='POST' and r['path']=='/api/v1/agent/state'"
check "state: Authorization Bearer" req 0 "$AUTH"
check "state: corps JSON" req 0 "r['body']=={'status':'working','detail':'Edit foo.ts','progress':40,'ttl_s':900}"
check "state: Content-Type JSON" req 0 "r['headers']['content-type']=='application/json'"

reset_log
configured "$SAN" state idle >/dev/null
check "state sans detail" req 0 "r['body']=={'status':'idle'}"

reset_log
configured "$SAN" state working 'Dis "bonjour"\ à la ligne
suivante	tab é' >/dev/null
check "state: échappement JSON (guillemets, \\, newline, UTF-8)" req 0 "r['body']['detail']=='Dis \"bonjour\"\\\\ à la ligne\nsuivante\ttab é'"

reset_log
configured "$SAN" nudge "Salut" --high >/dev/null
check "nudge: POST /agent/nudge high" req 0 "r['method']=='POST' and r['path']=='/api/v1/agent/nudge' and r['body']=={'text':'Salut','priority':'high'} and $AUTH"
reset_log
configured "$SAN" nudge >/dev/null
check "nudge sans texte" req 0 "r['body']=={}"

for t in start notification question "done" error; do
  reset_log
  configured "$SAN" nudge "Texte $t" --type "$t" >/dev/null
  check "nudge --type $t: champ type envoyé" req 0 "r['path']=='/api/v1/agent/nudge' and r['body']=={'text':'Texte $t','type':'$t'}"
done
reset_log
configured "$SAN" nudge "Q" --type question --high --ttl 30 >/dev/null
check "nudge --type + --high + --ttl" req 0 "r['body']=={'text':'Q','priority':'high','type':'question','ttl_s':30}"
reset_log
configured "$SAN" nudge "Défaut" >/dev/null
check "nudge sans --type: champ absent" req 0 "'type' not in r['body']"
reset_log
out="$(bash -c "SAN_URL=$URL SAN_TOKEN=$TOKEN '$SAN' nudge x --type bogus" 2>&1)"; rc=$?
[ "$rc" = 2 ] && [ "$(count)" = 0 ] && printf '%s' "$out" | grep -q 'start|notification|question|done|error' && ok "nudge --type invalide: code 2, message clair, aucune requête" || ko "nudge --type invalide (rc=$rc)"
bash -c "SAN_URL=$URL SAN_TOKEN=$TOKEN '$SAN' nudge x --type" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "nudge --type sans valeur: code 2" || ko "nudge --type sans valeur: code $rc"
bash -c "SAN_URL=$URL SAN_TOKEN=$TOKEN '$SAN' say x --type done" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "say --type: code 2" || ko "say --type: code $rc"
reset_log
curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"text":"x","type":"bogus"}' "$URL/api/v1/agent/nudge" >"$TMP/code"
[ "$(cat "$TMP/code")" = 400 ] && ok "mock: type inconnu -> 400" || ko "mock: type inconnu -> $(cat "$TMP/code")"
curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"text":"x","type":"done"}' "$URL/api/v1/agent/nudge" >"$TMP/code"
[ "$(cat "$TMP/code")" = 200 ] && ok "mock: type valide -> 200" || ko "mock: type valide -> $(cat "$TMP/code")"

reset_log
configured "$SAN" say "J'ai besoin de ta validation" --ttl 60 >/dev/null
check "say: POST /agent/say" req 0 "r['method']=='POST' and r['path']=='/api/v1/agent/say' and r['body']=={'text':\"J'ai besoin de ta validation\",'ttl_s':60} and $AUTH"

printf 'RIFFxxxx' >"$TMP/a.wav"; printf 'ID3xx' >"$TMP/a.mp3"; printf 'OggSxx' >"$TMP/a.ogg"
reset_log
configured "$SAN" voice "$TMP/a.wav" >/dev/null
configured "$SAN" voice "$TMP/a.mp3" >/dev/null
configured "$SAN" voice "$TMP/a.ogg" >/dev/null
check "voice wav: POST /agent/voice audio/wav" req 0 "r['method']=='POST' and r['path']=='/api/v1/agent/voice' and r['headers']['content-type']=='audio/wav' and r['body_len']==8 and $AUTH"
check "voice mp3: audio/mpeg" req 1 "r['headers']['content-type']=='audio/mpeg'"
check "voice ogg: audio/ogg" req 2 "r['headers']['content-type']=='audio/ogg'"

reset_log
out="$(configured "$SAN" inbox --wait 3 --ack 811)"
check "inbox: GET /agent/inbox?ack&wait" req 0 "r['method']=='GET' and r['path']=='/api/v1/agent/inbox' and r['query']=={'ack':'811','wait':'3'} and $AUTH"
check "inbox: sortie JSON" python3 -I -c 'import json,sys; assert json.loads(sys.argv[1])["events"][0]["id"]==812' "$out"
reset_log
configured "$SAN" inbox >/dev/null
check "inbox sans option" req 0 "r['query']=={}"

reset_log
f="$(cd "$TMP" && configured "$SAN" fetch-voice c_TEST --format mp3)"
check "fetch-voice: GET /agent/voice/c_TEST?format=mp3" req 0 "r['method']=='GET' and r['path']=='/api/v1/agent/voice/c_TEST' and r['query']=={'format':'mp3'} and $AUTH"
check "fetch-voice: fichier par défaut c_TEST.mp3" test -s "$TMP/c_TEST.mp3"
configured "$SAN" fetch-voice c_TEST -o "$TMP/out.wav" >/dev/null
check "fetch-voice -o: contenu" grep -q RIFFfakewavdata "$TMP/out.wav"
check "fetch-voice: affiche le chemin" test "$f" = "c_TEST.mp3"

echo "== bin/san : erreurs d'usage"
bash -c "SAN_URL=$URL SAN_TOKEN=$TOKEN '$SAN' state bogus" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "status invalide: code 2" || ko "status invalide: code $rc"
bash -c "SAN_URL=$URL SAN_TOKEN=$TOKEN '$SAN' state working x --progress 101" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "progress hors bornes: code 2" || ko "progress hors bornes: code $rc"
bash -c "SAN_URL=$URL SAN_TOKEN=$TOKEN '$SAN' fetch-voice '../etc'" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "fetch-voice id invalide: code 2" || ko "fetch-voice id invalide: code $rc"

echo "== bin/san : configuration"
reset_log
mkdir -p "$HOME/.config/san"
printf '# commentaire\nSAN_URL=%s/\nexport SAN_TOKEN="%s"\n' "$URL" "$TOKEN" >"$HOME/.config/san/agent.env"
"$SAN" state idle >/dev/null
check "fichier agent.env (URL avec / final, guillemets, export)" req 0 "r['path']=='/api/v1/agent/state' and $AUTH"
reset_log
SAN_TOKEN=agt_autre "$SAN" state idle >/dev/null
check "l'environnement prime sur le fichier" req 0 "r['headers']['authorization']=='Bearer agt_autre'"
rm -f "$HOME/.config/san/agent.env"

echo "== bin/san : non configuré / serveur injoignable / jeton refusé"
reset_log
out="$("$SAN" state working x 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && [ "$(count)" = 0 ] && ok "non configuré: silencieux, code 0, aucune requête" || ko "non configuré (rc=$rc out=$out)"
t0=$(date +%s)
out="$(SAN_URL=http://127.0.0.1:1 SAN_TOKEN=x "$SAN" state working x 2>&1)"; rc=$?
t1=$(date +%s)
[ "$rc" = 0 ] && [ -z "$out" ] && [ $((t1 - t0)) -le 3 ] && ok "serveur down: silencieux, code 0, rapide" || ko "serveur down (rc=$rc, $((t1 - t0))s)"
SAN_STRICT=1 SAN_URL=http://127.0.0.1:1 SAN_TOKEN=x "$SAN" state idle >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok "SAN_STRICT=1: code 1 si injoignable" || ko "SAN_STRICT code $rc"
SAN_URL="$URL" SAN_TOKEN=mauvais "$SAN" state idle >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "401: code 0" || ko "401: code $rc"
SAN_STRICT=1 SAN_URL="$URL" SAN_TOKEN=mauvais "$SAN" state idle >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok "401 + SAN_STRICT=1: code 1" || ko "401 strict: code $rc"
reset_log

# --- enrôlement -------------------------------------------------------------
echo "== bin/san : register"
ENR=enr_goodtoken
EF="$TMP/reg/agent.env"
regrun() { SAN_URL="$URL" SAN_ENV_FILE="$EF" "$SAN" register "$@"; }
reset_log; rm -rf "$TMP/reg"
out="$(regrun mon/agent --name "Mon agent" --enrollment-token "$ENR" 2>&1)"; rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'actif (groupe equipe)' && ok "register actif: code 0, message avec groupe" || ko "register actif rc=$rc out=$out"
check "register: POST /agent/register sans Authorization, corps JSON" req 0 "r['path']=='/api/v1/agent/register' and 'authorization' not in r['headers'] and r['body']=={'slug':'mon/agent','name':'Mon agent','enrollment_token':'$ENR'}"
check "register: SAN_TOKEN et SAN_URL écrits" bash -c "grep -qx 'SAN_TOKEN=agt_SECRETNEW' '$EF' && grep -qx 'SAN_URL=$URL' '$EF'"
[ "$(ls -l "$EF" | cut -c1-10)" = "-rw-------" ] && ok "register: fichier d'env en 0600" || ko "register: permissions"
printf '%s' "$out" | grep -q 'agt_\|enr_' && ko "register: jeton affiché dans la sortie" || ok "register: aucun jeton dans la sortie"

# ne pas écraser ; autres variables conservées ; --force
printf 'SAN_NUDGE_START=1\n# note\nSAN_TOKEN=agt_ancien\nSAN_URL=%s\nAUTRE=x y\n' "$URL" >"$EF"
reset_log
out="$(regrun a1 --enrollment-token "$ENR" 2>&1)"; rc=$?
[ "$rc" = 1 ] && [ "$(count)" = 0 ] && grep -qx 'SAN_TOKEN=agt_ancien' "$EF" && ok "register: n'écrase pas un SAN_TOKEN existant (aucune requête)" || ko "register sans --force rc=$rc"
out="$(regrun a1 --enrollment-token "$ENR" --force 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -qx 'SAN_TOKEN=agt_SECRETNEW' "$EF" && ! grep -q agt_ancien "$EF" && ok "register --force: remplace le jeton" || ko "register --force rc=$rc"
check "register --force: autres variables conservées" bash -c "grep -qx 'SAN_NUDGE_START=1' '$EF' && grep -qx '# note' '$EF' && grep -qx 'AUTRE=x y' '$EF' && [ \$(grep -c '^SAN_TOKEN=' '$EF') = 1 ]"
printf '%s' "$out" | grep -q 'agt_\|enr_' && ko "register --force: jeton affiché" || ok "register --force: aucun jeton dans la sortie"

# pending
rm -f "$EF"; reset_log
out="$(regrun p1 2>&1)"; rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q "attente d'approbation" && printf '%s' "$out" | grep -q 'san register --status' && ok "register pending: message et rappel --status" || ko "register pending rc=$rc out=$out"
check "register pending: pas d'enrollment_token envoyé" req 0 "r['body']=={'slug':'p1'}"
grep -qx 'SAN_TOKEN=agt_PENDINGTOK' "$EF" && ok "register pending: jeton enregistré" || ko "register pending: jeton"
printf '%s' "$out" | grep -q 'agt_\|enr_' && ko "register pending: jeton affiché" || ok "register pending: aucun jeton dans la sortie"

# erreurs
rm -f "$EF"
out="$(regrun a --enrollment-token enr_mauvais 2>&1)"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q "jeton d'enrôlement invalide" && [ ! -e "$EF" ] && ok "register 401: message, rien écrit" || ko "register 401 rc=$rc out=$out"
printf '%s' "$out" | grep -q 'enr_' && ko "register 401: jeton affiché" || ok "register 401: jeton absent de la sortie"
out="$(regrun taken 2>&1)"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q "déjà pris" && [ ! -e "$EF" ] && ok "register 409: slug pris" || ko "register 409 rc=$rc out=$out"
out="$(regrun limited 2>&1)"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q "trop de demandes" && printf '%s' "$out" | grep -q '7 s' && ok "register 429: trop de demandes + Retry-After" || ko "register 429 rc=$rc out=$out"
out="$(regrun "bad slug" 2>&1)"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q "invalide" && ok "register 400: invalide" || ko "register 400 rc=$rc"
out="$(SAN_URL=http://127.0.0.1:1 SAN_ENV_FILE="$EF" "$SAN" register x 2>&1)"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q injoignable && ok "register: serveur injoignable" || ko "register injoignable rc=$rc"
regrun >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "register sans slug: code 2" || ko "register sans slug rc=$rc"
regrun x --enrollment-token abc >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "register: jeton sans préfixe enr_ refusé (code 2)" || ko "register jeton mal formé rc=$rc"

# jeton d'enrôlement par l'environnement et par stdin
rm -f "$EF"; reset_log
SAN_ENROLLMENT_TOKEN="$ENR" regrun e1 >/dev/null 2>&1
check "register: SAN_ENROLLMENT_TOKEN pris en compte" req 0 "r['body'].get('enrollment_token')=='$ENR'"
rm -f "$EF"; reset_log
printf '%s\n' "$ENR" | regrun e2 --enrollment-token - >/dev/null 2>&1
check "register --enrollment-token - : lu sur stdin" req 0 "r['body'].get('enrollment_token')=='$ENR'"

# --status
echo "== bin/san : register --status"
out="$(SAN_URL="$URL" SAN_TOKEN=agt_PENDINGTOK "$SAN" register --status 2>&1)"; rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q '^pending' && ok "status: pending" || ko "status pending rc=$rc out=$out"
out="$(SAN_URL="$URL" SAN_TOKEN=agt_SECRETNEW "$SAN" register --status 2>&1)"; rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q '^active' && ok "status: active" || ko "status active rc=$rc out=$out"
reset_log
out="$(SAN_URL="$URL" SAN_TOKEN=agt_gone "$SAN" register --status 2>&1)"; rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'rejeté ou révoqué' && ok "status 401: rejeté ou révoqué" || ko "status 401 rc=$rc out=$out"
check "status: GET /agent/status avec Bearer" req 0 "r['method']=='GET' and r['path']=='/api/v1/agent/status' and r['headers']['authorization']=='Bearer agt_gone'"
printf '%s' "$out" | grep -q 'agt_' && ko "status: jeton affiché" || ok "status: jeton absent de la sortie"
out="$(SAN_URL="$URL" SAN_ENV_FILE="$TMP/inexistant" "$SAN" register --status 2>&1)"; rc=$?
[ "$rc" = 1 ] && ok "status sans jeton: erreur claire" || ko "status sans jeton rc=$rc"

# agent pending : les commandes restent silencieuses (code 0) ; message seulement en debug
out="$(SAN_URL="$URL" SAN_TOKEN=agt_PENDINGTOK "$SAN" state idle 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok "agent pending: state silencieux, code 0" || ko "agent pending rc=$rc out=$out"
out="$(SAN_DEBUG=1 SAN_URL="$URL" SAN_TOKEN=agt_PENDINGTOK "$SAN" state idle 2>&1)"
printf '%s' "$out" | grep -q 'san register --status' && ok "agent pending: SAN_DEBUG indique san register --status" || ko "agent pending debug: $out"
out="$(printf '{"session_id":"pend"}' | SAN_URL="$URL" SAN_TOKEN=agt_PENDINGTOK "$ROOT/hooks/stop.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok "agent pending: hook Stop silencieux, code 0" || ko "hook pending rc=$rc out=$out"
reset_log

# --- hooks -------------------------------------------------------------------
echo "== hooks"
run_hook() { # nom json  (serveur configuré)
  local name="$1" json="$2"
  printf '%s' "$json" | SAN_URL="$URL" SAN_TOKEN="$TOKEN" "$ROOT/hooks/$name.sh"
}
S='"session_id":"sess-1","cwd":"/tmp"'

reset_log; rm -rf "$SAN_STATE_DIR"
out="$(run_hook session-start "{$S,\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}")"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok "SessionStart: code 0, aucune sortie" || ko "SessionStart rc=$rc out=$out"
check "SessionStart -> idle + ttl" req 0 "r['path']=='/api/v1/agent/state' and r['method']=='POST' and r['body']['status']=='idle' and r['body']['ttl_s']>0 and $AUTH"
[ "$(count)" = 1 ] && ok "SessionStart: aucun nudge" || ko "SessionStart: $(count) requêtes"

reset_log
out="$(run_hook user-prompt-submit "{$S,\"prompt\":\"Refactorise le module de paiement et corrige tous les tests qui échouent depuis hier soir sur la CI\"}")"
[ -z "$out" ] && ok "UserPromptSubmit: aucune sortie" || ko "UserPromptSubmit sortie: $out"
check "UserPromptSubmit -> working, detail <= 60 car." req 0 "r['body']['status']=='working' and 0<len(r['body']['detail'])<=60 and r['body']['detail'].startswith('Refactorise le module') and r['body']['ttl_s']>0 and $AUTH"
reset_log
run_hook user-prompt-submit "{$S,\"prompt\":\"utilise le token sk-abcdefghijklmnop1234 et password=hunter2 avec Bearer abcdefgh12345678abcdefgh\"}" >/dev/null
check "UserPromptSubmit: secrets masqués" req 0 "'sk-abc' not in r['body']['detail'] and 'hunter2' not in r['body']['detail'] and 'abcdefgh1234' not in r['body']['detail']"

reset_log; rm -rf "$SAN_STATE_DIR"
run_hook post-tool-use "{$S,\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/repo/src/foo.ts\",\"old_string\":\"a\"}}" >/dev/null
check "PostToolUse Edit -> « Edit foo.ts »" req 0 "r['body']['status']=='working' and r['body']['detail']=='Edit foo.ts' and $AUTH"
run_hook post-tool-use "{$S,\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/repo/bar.ts\"}}" >/dev/null
[ "$(count)" = 1 ] && ok "PostToolUse: throttling (2e appel ignoré)" || ko "throttling: $(count) requêtes"
echo 1 >"$SAN_STATE_DIR/sess-1.last"
run_hook post-tool-use "{$S,\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"curl -H 'Authorization: x' https://secret\"}}" >/dev/null
check "PostToolUse Bash: seul le 1er mot" req 1 "r['body']['detail']=='Bash curl'"
echo 1 >"$SAN_STATE_DIR/sess-1.last"
run_hook post-tool-use "{$S,\"tool_name\":\"Grep\",\"tool_input\":{\"pattern\":\"x\"}}" >/dev/null
check "PostToolUse Grep -> « Grep »" req 2 "r['body']['detail']=='Grep'"

reset_log
run_hook notification "{$S,\"notification_type\":\"permission_prompt\",\"message\":\"Claude needs your permission to use Bash\"}" >/dev/null
check "Notification -> nudge type question" req 0 "r['body']['type']=='question' and r['body']['priority']=='high' and r['path']=='/api/v1/agent/nudge' and 'permission' in r['body']['text'] and $AUTH"
[ "$(count)" = 1 ] && ok "Notification: nudge seul, aucun state (pas d'icône intermédiaire)" || ko "Notification: $(count) requêtes"
reset_log
run_hook notification "{$S,\"notification_type\":\"idle_prompt\",\"message\":\"Claude is waiting for your input\"}" >/dev/null
[ "$(count)" = 0 ] && ok "Notification idle_prompt ignorée (pas de doublon après Stop)" || ko "idle_prompt non ignorée"
reset_log
run_hook post-tool-use "{$S,\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"a.ts\"}}" >/dev/null
[ "$(count)" = 1 ] && ok "après Notification: le throttling est levé" || ko "throttle après Notification"
reset_log
run_hook notification "{$S,\"notification_type\":\"auth_success\",\"message\":\"ok\"}" >/dev/null
[ "$(count)" = 0 ] && ok "Notification auth_success ignorée" || ko "auth_success non ignorée"

reset_log
run_hook stop "{$S,\"hook_event_name\":\"Stop\",\"stop_hook_active\":false}" >/dev/null
check "Stop -> state done" req 0 "r['path']=='/api/v1/agent/state' and r['body']['status']=='done' and r['body']['ttl_s']>0 and $AUTH"
check "Stop -> nudge « Tâche terminée » (normal)" req 1 "r['path']=='/api/v1/agent/nudge' and r['body']=={'text':'Tâche terminée','type':'done'} and $AUTH"

reset_log
run_hook session-end "{$S,\"reason\":\"other\"}" >/dev/null
check "SessionEnd -> idle" req 0 "r['body']['status']=='idle' and r['body']['ttl_s']>0 and $AUTH"

echo "== hooks : asynchrone (mode par défaut)"
reset_log
printf '%s' "{$S}" | SAN_HOOK_SYNC=0 SAN_URL="$URL" SAN_TOKEN="$TOKEN" "$ROOT/hooks/stop.sh"; rc=$?
for _ in $(seq 1 30); do [ "$(count)" -ge 2 ] && break; sleep 0.1; done
[ "$rc" = 0 ] && [ "$(count)" = 2 ] && ok "Stop asynchrone: 2 requêtes ordonnées" || ko "Stop async (rc=$rc, $(count) requêtes)"

echo "== hooks : sans jq"
NOJQ="$TMP/nojq"; mkdir -p "$NOJQ"
for b in bash sh curl sed tr head cat date id mkdir chmod dirname mktemp rm mv cmp grep python3 sleep basename; do
  p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$NOJQ/$b"
done
reset_log; rm -rf "$SAN_STATE_DIR"
printf '%s' "{$S,\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/repo/src/foo.ts\"}}" \
  | PATH="$NOJQ" SAN_URL="$URL" SAN_TOKEN="$TOKEN" "$ROOT/hooks/post-tool-use.sh"
check "sans jq: PostToolUse « Edit foo.ts »" req 0 "r['body']['detail']=='Edit foo.ts'"
printf '%s' "{$S,\"prompt\":\"Dis \\\"salut\\\" à Bob\"}" \
  | PATH="$NOJQ" SAN_URL="$URL" SAN_TOKEN="$TOKEN" "$ROOT/hooks/user-prompt-submit.sh"
check "sans jq: UserPromptSubmit (guillemets échappés)" req 1 "r['body']['detail']=='Dis \"salut\" à Bob'"

echo "== hooks : nudge start (SAN_NUDGE_START) et StopFailure"
reset_log; rm -rf "$SAN_STATE_DIR"
run_hook user-prompt-submit "{$S,\"prompt\":\"Premier prompt\"}" >/dev/null
[ "$(count)" = 1 ] && check "nudge start désactivé par défaut: working seul" req 0 "r['body']['status']=='working'" || ko "nudge start par défaut: $(count) requêtes"
reset_log; rm -rf "$SAN_STATE_DIR"
printf '%s' "{$S,\"prompt\":\"Premier prompt\"}" | SAN_NUDGE_START=1 SAN_URL="$URL" SAN_TOKEN="$TOKEN" "$ROOT/hooks/user-prompt-submit.sh"
check "nudge start activé: nudge start puis working (icône finale = réflexion)" req 0 "r['path']=='/api/v1/agent/nudge' and r['body']['type']=='start' and $AUTH"
check "nudge start activé: working en dernier" req 1 "r['path']=='/api/v1/agent/state' and r['body']['status']=='working'"
[ "$(count)" = 2 ] && ok "nudge start activé: 2 requêtes" || ko "nudge start activé: $(count) requêtes"
printf '%s' "{$S,\"prompt\":\"Deuxième prompt enchaîné\"}" | SAN_NUDGE_START=1 SAN_URL="$URL" SAN_TOKEN="$TOKEN" "$ROOT/hooks/user-prompt-submit.sh"
[ "$(count)" = 3 ] && ok "nudge start: pas de doublon sur prompts enchaînés" || ko "doublon nudge start: $(count) requêtes"
run_hook stop "{$S}" >/dev/null
printf '%s' "{$S,\"prompt\":\"Nouveau tour\"}" | SAN_NUDGE_START=1 SAN_URL="$URL" SAN_TOKEN="$TOKEN" "$ROOT/hooks/user-prompt-submit.sh"
check "nudge start: de nouveau après Stop" req 5 "r['path']=='/api/v1/agent/nudge' and r['body']['type']=='start'"
echo $(($(date +%s) - 1000)) >"$SAN_STATE_DIR/sess-1.last"
reset_log
printf '%s' "{$S,\"prompt\":\"Après longue pause\"}" | SAN_NUDGE_START=1 SAN_URL="$URL" SAN_TOKEN="$TOKEN" "$ROOT/hooks/user-prompt-submit.sh"
[ "$(count)" = 2 ] && ok "nudge start: de nouveau si working > 300 s" || ko "nudge start après fenêtre: $(count)"
rm -rf "$SAN_STATE_DIR"; reset_log
printf 'SAN_NUDGE_START=1\n' >"$TMP/nudge.env"
printf '%s' "{$S,\"prompt\":\"via fichier\"}" | SAN_ENV_FILE="$TMP/nudge.env" SAN_URL="$URL" SAN_TOKEN="$TOKEN" "$ROOT/hooks/user-prompt-submit.sh"
[ "$(count)" = 2 ] && ok "SAN_NUDGE_START lu depuis le fichier d'env" || ko "SAN_NUDGE_START fichier: $(count)"

reset_log
out="$(run_hook stop-failure "{$S,\"hook_event_name\":\"StopFailure\",\"error\":\"rate_limit\",\"error_details\":\"429\",\"last_assistant_message\":\"API Error: Rate limit reached\"}")"
[ -z "$out" ] && ok "StopFailure: aucune sortie" || ko "StopFailure sortie: $out"
check "StopFailure -> state error + detail" req 0 "r['path']=='/api/v1/agent/state' and r['body']['status']=='error' and r['body']['detail']=='Erreur : rate_limit' and r['body']['ttl_s']>0 and $AUTH"
check "StopFailure -> nudge error high" req 1 "r['path']=='/api/v1/agent/nudge' and r['body']=={'text':'Erreur : rate_limit','type':'error','priority':'high'} and $AUTH"
reset_log
run_hook stop-failure "{$S,\"hook_event_name\":\"StopFailure\"}" >/dev/null
check "StopFailure sans champs -> « Erreur »" req 1 "r['body']['text']=='Erreur' and r['body']['type']=='error'"
reset_log
printf '%s' "{$S,\"error\":\"server_error\"}" | PATH="$NOJQ" SAN_URL="$URL" SAN_TOKEN="$TOKEN" "$ROOT/hooks/stop-failure.sh"
check "sans jq: StopFailure « Erreur : server_error »" req 1 "r['body']['text']=='Erreur : server_error'"
reset_log
printf '%s' "{$S,\"prompt\":\"x\"}" | PATH="$NOJQ" SAN_NUDGE_START=1 SAN_URL="$URL" SAN_TOKEN="$TOKEN" "$ROOT/hooks/user-prompt-submit.sh"
rm -rf "$SAN_STATE_DIR"
printf '%s' "{$S,\"prompt\":\"x\"}" | PATH="$NOJQ" SAN_NUDGE_START=1 SAN_URL="$URL" SAN_TOKEN="$TOKEN" "$ROOT/hooks/user-prompt-submit.sh"
check "sans jq: nudge start" req 2 "r['body'].get('type')=='start'"

echo "== hooks : sous-agents actifs (SubagentStart / SubagentStop)"
SA="\"session_id\":\"sa-1\""
sub_start() { run_hook subagent-start "{$SA,\"hook_event_name\":\"SubagentStart\",\"agent_id\":\"$1\",\"agent_type\":\"Explore\"}"; }
sub_stop() { run_hook subagent-stop "{${2:-$SA},\"hook_event_name\":\"SubagentStop\",\"agent_id\":\"${1:-}\",\"agent_type\":\"Explore\",\"stop_hook_active\":false}"; }
sa_stop_main() { run_hook stop "{${1:-$SA},\"hook_event_name\":\"Stop\",\"stop_hook_active\":false}"; }
rm -rf "$SAN_STATE_DIR"; reset_log
sa_stop_main >/dev/null
check "sous-agents: Stop sans sous-agent -> done + nudge done" req 1 "r['path']=='/api/v1/agent/nudge' and r['body']['type']=='done'"
reset_log
out="$(sub_start a1)"
[ -z "$out" ] && [ "$(count)" = 0 ] && ok "SubagentStart: silencieux, aucune requête" || ko "SubagentStart sortie/requêtes"
sa_stop_main >/dev/null
[ "$(count)" = 1 ] && check "sous-agents: 1 actif -> Stop publie working (« 1 sous-agent en cours »)" req 0 "r['path']=='/api/v1/agent/state' and r['body']['status']=='working' and r['body']['detail']=='1 sous-agent en cours' and r['body']['ttl_s']==900" || ko "1 actif: $(count) requêtes"
check "sous-agents: 1 actif -> pas de done ni de nudge" bash -c "! grep -q '\"done\"\\|nudge' '$LOG'"
reset_log
sub_start a2 >/dev/null; sub_stop a1 >/dev/null
sa_stop_main >/dev/null
check "sous-agents: 2 starts / 1 stop -> toujours actif" req 0 "r['body']['status']=='working' and r['body']['detail']=='1 sous-agent en cours'"
reset_log
sub_start a3 >/dev/null; sub_start a3 >/dev/null
sa_stop_main >/dev/null
check "sous-agents: SubagentStart répété (même id) idempotent -> 2 actifs" req 0 "r['body']['detail']=='2 sous-agents en cours'"
reset_log
out="$(sub_stop a2; sub_stop a3)"
[ -z "$out" ] && [ "$(count)" = 0 ] && ok "SubagentStop: silencieux, aucune requête (pas de done inventé)" || ko "SubagentStop sortie/requêtes"
sa_stop_main >/dev/null
check "sous-agents: tous terminés -> Stop envoie done" req 0 "r['body']['status']=='done'"
check "sous-agents: tous terminés -> nudge done" req 1 "r['body']=={'text':'Tâche terminée','type':'done'}"
reset_log
sub_stop zzz >/dev/null; sub_stop zzz >/dev/null; sub_stop >/dev/null
sub_start b1 >/dev/null
sa_stop_main >/dev/null
check "sous-agents: décrément borné à 0 (stops en trop ignorés) -> 1 actif" req 0 "r['body']['status']=='working' and r['body']['detail']=='1 sous-agent en cours'"
sub_stop b1 >/dev/null
reset_log
printf 'old1 %s\nold2 %s\n' "$(( $(date +%s) - 7300 ))" "$(( $(date +%s) - 9000 ))" >"$SAN_STATE_DIR/sa-1.subagents"
sa_stop_main >/dev/null
check "sous-agents: compteur expiré (> 2 h) -> done" req 0 "r['body']['status']=='done'"
reset_log
sub_start c1 >/dev/null
sa_stop_main '"session_id":"sa-2"' >/dev/null
check "sous-agents: isolation entre sessions (autre session -> done)" req 0 "r['body']['status']=='done'"
reset_log
sub_stop c1 '"session_id":"sa-2"' >/dev/null
sa_stop_main >/dev/null
check "sous-agents: SubagentStop d'une autre session sans effet" req 0 "r['body']['status']=='working'"
reset_log
run_hook session-start "{$SA}" >/dev/null
sa_stop_main >/dev/null
check "sous-agents: SessionStart réinitialise le compteur" req 1 "r['body']['status']=='done'"
sub_start d1 >/dev/null
run_hook session-end "{$SA}" >/dev/null
reset_log; sa_stop_main >/dev/null
check "sous-agents: SessionEnd réinitialise le compteur" req 0 "r['body']['status']=='done'"
sub_start d2 >/dev/null
run_hook stop-failure "{$SA,\"error\":\"rate_limit\"}" >/dev/null
reset_log; sa_stop_main >/dev/null
check "sous-agents: StopFailure réinitialise le compteur" req 0 "r['body']['status']=='done'"
sub_start e1 >/dev/null; sub_start e2 >/dev/null
pids=""
for i in 1 2 3 4 5 6; do sub_start "p$i" >/dev/null & pids="$pids $!"; done
# shellcheck disable=SC2086
wait $pids
n="$(grep -c . "$SAN_STATE_DIR/sa-1.subagents")"
[ "$n" = 8 ] && ok "sous-agents: 8 SubagentStart concurrents -> 8 entrées" || ko "concurrence: $n entrées"
check "sous-agents: verrou libéré" test ! -d "$SAN_STATE_DIR/sa-1.subagents.lock"
rm -rf "$SAN_STATE_DIR"; reset_log
printf '%s' "{$SA,\"agent_id\":\"n1\"}" | PATH="$NOJQ" "$ROOT/hooks/subagent-start.sh"
printf '%s' "{$SA}" | PATH="$NOJQ" SAN_URL="$URL" SAN_TOKEN="$TOKEN" "$ROOT/hooks/stop.sh"
check "sans jq: SubagentStart + Stop -> working" req 0 "r['body']['status']=='working'"
printf '%s' "{$SA,\"agent_id\":\"n1\"}" | PATH="$NOJQ" "$ROOT/hooks/subagent-stop.sh"
printf '%s' "{$SA}" | PATH="$NOJQ" SAN_URL="$URL" SAN_TOKEN="$TOKEN" "$ROOT/hooks/stop.sh"
check "sans jq: SubagentStop + Stop -> done" req 1 "r['body']['status']=='done'"
rm -rf "$SAN_STATE_DIR"; reset_log

echo "== hooks : Stop et background_tasks (autorité sur le registre)"
bgstop() { run_hook stop "{$SA,\"hook_event_name\":\"Stop\",\"background_tasks\":$1}"; }
rm -rf "$SAN_STATE_DIR"; reset_log
sub_start g1 >/dev/null
bgstop '[]' >/dev/null
check "background_tasks vide + registre non vide -> done" req 0 "r['body']['status']=='done'"
check "background_tasks vide -> registre purgé" test ! -s "$SAN_STATE_DIR/sa-1.subagents"
reset_log
bgstop '[{"id":"t1","type":"subagent","status":"running","description":"x","agent_type":"Explore"}]' >/dev/null
[ "$(count)" = 1 ] && check "un subagent running + registre vide -> working, sans done" req 0 "r['body']['status']=='working' and r['body']['detail']=='1 sous-agent en cours'" || ko "subagent running: $(count) requêtes"
reset_log
bgstop '[{"id":"t1","type":"subagent","status":"completed"},{"id":"t2","type":"subagent","status":"failed"},{"id":"t3","type":"subagent","status":"killed"}]' >/dev/null
check "subagents terminés/échoués/tués -> done" req 0 "r['body']['status']=='done'"
reset_log
bgstop '[{"id":"t1","type":"shell","status":"running","command":"tail -f x"},{"id":"t2","type":"monitor","status":"running"}]' >/dev/null
check "types non-subagent ignorés -> done" req 0 "r['body']['status']=='done'"
reset_log
bgstop '[{"type":"shell","status":"running"},{"type":"subagent","status":"running"},{"type":"subagent","status":"completed"},{"type":"subagent","status":"running"}]' >/dev/null
check "mélange -> compte seulement les subagents actifs (2)" req 0 "r['body']['detail']=='2 sous-agents en cours'"
reset_log
sub_start g2 >/dev/null
sa_stop_main >/dev/null
check "clé background_tasks absente -> registre (working)" req 0 "r['body']['status']=='working'"
reset_log
printf '{"agent_id":"ns1"}' | "$ROOT/hooks/subagent-start.sh"
printf '{"background_tasks":[]}' | PATH="$NOJQ" SAN_URL="$URL" SAN_TOKEN="$TOKEN" "$ROOT/hooks/stop.sh"
check "sans jq: repli sur le registre (working malgré background_tasks vide)" req 0 "r['body']['status']=='working'"
rm -rf "$SAN_STATE_DIR"; reset_log

echo "== hooks : non configuré / serveur injoignable / entrée vide"
for h in session-start user-prompt-submit post-tool-use notification stop stop-failure session-end subagent-start subagent-stop; do
  for mode in unconfigured down; do
    rm -rf "$SAN_STATE_DIR"; reset_log
    t0=$(date +%s)
    if [ "$mode" = down ]; then
      out="$(printf '{"session_id":"s","prompt":"x","tool_name":"Edit"}' | SAN_URL=http://127.0.0.1:1 SAN_TOKEN=x "$ROOT/hooks/$h.sh" 2>&1)"; rc=$?
    else
      out="$(printf '{"session_id":"s","prompt":"x","tool_name":"Edit"}' | "$ROOT/hooks/$h.sh" 2>&1)"; rc=$?
    fi
    t1=$(date +%s)
    [ "$rc" = 0 ] && [ -z "$out" ] && [ $((t1 - t0)) -le 4 ] && ok "$h ($mode): code 0, silencieux, rapide" || ko "$h ($mode): rc=$rc out=$out $((t1 - t0))s"
  done
done
for h in session-start user-prompt-submit post-tool-use notification stop stop-failure session-end subagent-start subagent-stop; do
  out="$("$ROOT/hooks/$h.sh" </dev/null 2>&1)"; rc=$?
  [ "$rc" = 0 ] && [ -z "$out" ] && ok "$h: stdin vide -> code 0" || ko "$h: stdin vide rc=$rc"
  printf 'pas du json {{{' | "$ROOT/hooks/$h.sh" >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] && ok "$h: JSON invalide -> code 0" || ko "$h: JSON invalide rc=$rc"
done

# --- faux agent --------------------------------------------------------------
echo "== tools/fake-agent.sh"
reset_log
configured "$ROOT/tools/fake-agent.sh" --once --interval 0 >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "fake-agent --once: code 0" || ko "fake-agent rc=$rc"
check "fake-agent: états working/error/done publiés, pas de waiting ni de nudge start" python3 -I -c '
import json,sys
rs=[json.loads(l) for l in open(sys.argv[1])]
st={r["body"]["status"] for r in rs if r["path"].endswith("/state")}
assert {"idle","working","error","done"} <= st and "waiting" not in st, st
assert any(r["path"].endswith("/say") for r in rs)
assert any(r["path"].endswith("/nudge") and r["body"].get("priority")=="high" and r["body"].get("type")=="question" for r in rs)
assert any(r["path"].endswith("/inbox") for r in rs)
nt=[r["body"].get("type","notification") for r in rs if r["path"].endswith("/nudge")]
assert {"question","error","done","notification"} <= set(nt) and "start" not in nt, nt
assert any("progress" in r["body"] for r in rs if r["path"].endswith("/state"))' "$LOG"

# --- install.sh --------------------------------------------------------------
echo "== install.sh"
if command -v jq >/dev/null 2>&1; then
  P="$TMP/proj"; mkdir -p "$P/.claude"
  cat >"$P/.claude/settings.json" <<'JSON'
{"permissions":{"allow":["Bash(ls)"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo autre"}]}]}}
JSON
  "$ROOT/install.sh" --project "$P" >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] && ok "install: code 0" || ko "install rc=$rc"
  check "install: conserve la config existante" jq -e '.permissions.allow[0]=="Bash(ls)" and (.hooks.Stop|map(.hooks[0].command)|index("echo autre")!=null)' "$P/.claude/settings.json"
  check "install: 9 événements SAN" jq -e '[.hooks|keys[]] | (index("SubagentStart")!=null and index("SubagentStop")!=null and index("StopFailure")!=null and index("SessionStart")!=null and index("UserPromptSubmit")!=null and index("PostToolUse")!=null and index("Notification")!=null and index("Stop")!=null and index("SessionEnd")!=null)' "$P/.claude/settings.json"
  "$ROOT/install.sh" --project "$P" >/dev/null 2>&1
  check "install idempotent (pas de doublon)" jq -e '(.hooks.Stop|length)==2' "$P/.claude/settings.json"
  check "install: StopFailure -> stop-failure.sh (1 seul)" jq -e '(.hooks.StopFailure|length)==1 and (.hooks.StopFailure[0].hooks[0].command|contains("/san/hooks/stop-failure.sh"))' "$P/.claude/settings.json"
  check "install: stop-failure.sh exécutable" test -x "$P/.claude/san/hooks/stop-failure.sh"
  check "install: subagent-start/stop -> 1 seul chacun" jq -e '(.hooks.SubagentStart|length)==1 and (.hooks.SubagentStop|length)==1 and (.hooks.SubagentStart[0].hooks[0].command|contains("/san/hooks/subagent-start.sh")) and (.hooks.SubagentStop[0].hooks[0].command|contains("/san/hooks/subagent-stop.sh"))' "$P/.claude/settings.json"
  check "install: hooks sous-agents installés et exécutables" test -x "$P/.claude/san/hooks/subagent-start.sh" -a -x "$P/.claude/san/hooks/subagent-stop.sh"
  check "settings.example.json: SubagentStart/SubagentStop présents" python3 -I -c 'import json,sys; h=json.load(open(sys.argv[1]))["hooks"]; assert "SubagentStart" in h and "SubagentStop" in h' "$ROOT/settings.example.json"
  # ré-exécution sur une installation antérieure (sans StopFailure)
  P4="$TMP/proj4"; mkdir -p "$P4"
  "$ROOT/install.sh" --project "$P4" >/dev/null 2>&1
  jq 'del(.hooks.StopFailure)' "$P4/.claude/settings.json" >"$TMP/old.json" && mv "$TMP/old.json" "$P4/.claude/settings.json"
  "$ROOT/install.sh" --project "$P4" >/dev/null 2>&1
  check "install: ré-exécution ajoute StopFailure sans doublon" jq -e '(.hooks.StopFailure|length)==1 and (.hooks.Stop|length)==1' "$P4/.claude/settings.json"
  jq 'del(.hooks.SubagentStart,.hooks.SubagentStop)' "$P4/.claude/settings.json" >"$TMP/old.json" && mv "$TMP/old.json" "$P4/.claude/settings.json"
  "$ROOT/install.sh" --project "$P4" >/dev/null 2>&1
  "$ROOT/install.sh" --project "$P4" >/dev/null 2>&1
  check "install: mise à jour d'une install antérieure ajoute SubagentStart/Stop sans doublon" jq -e '(.hooks.SubagentStart|length)==1 and (.hooks.SubagentStop|length)==1' "$P4/.claude/settings.json"
  check "install: fichiers" test -x "$P/.claude/san/bin/san" -a -x "$P/.claude/san/hooks/stop.sh" -a -f "$P/.claude/skills/san/SKILL.md" -a -f "$P/.claude/commands/san-inbox.md" -a -f "$P/.claude/settings.json.bak"
  check "install: @SAN_BIN@ substitué" bash -c "! grep -q @SAN_BIN@ '$P/.claude/skills/san/SKILL.md' && grep -q '$P/.claude/san/bin/san' '$P/.claude/skills/san/SKILL.md'"
  # le hook installé fonctionne
  reset_log
  printf '{"session_id":"i1"}' | SAN_URL="$URL" SAN_TOKEN="$TOKEN" "$P/.claude/san/hooks/stop.sh"
  check "install: hook installé fonctionnel" req 0 "r['body']['status']=='done'"
  # config invalide
  P2="$TMP/proj2"; mkdir -p "$P2/.claude"; echo '{pas du json' >"$P2/.claude/settings.json"
  "$ROOT/install.sh" --project "$P2" >/dev/null 2>&1; rc=$?
  [ "$rc" != 0 ] && grep -q 'pas du json' "$P2/.claude/settings.json" && ok "install: refuse un settings.json invalide sans --force" || ko "install invalide rc=$rc"
  "$ROOT/install.sh" --project "$P2" --force >/dev/null 2>&1
  check "install --force: remplace" jq -e '.hooks.Stop' "$P2/.claude/settings.json"
  # skill modifiée
  echo "modif" >>"$P/.claude/skills/san/SKILL.md"
  "$ROOT/install.sh" --project "$P" >/dev/null 2>&1; rc=$?
  [ "$rc" != 0 ] && ok "install: refuse d'écraser une skill modifiée sans --force" || ko "skill modifiée rc=$rc"
  # global
  G="$TMP/g"; mkdir -p "$G"
  HOME="$G" "$ROOT/install.sh" --global >/dev/null 2>&1
  check "install --global: ~/.claude/settings.json avec \$HOME" bash -c "jq -e '.hooks.Stop[0].hooks[0].command | contains(\"\$HOME/.claude/san/hooks\")' '$G/.claude/settings.json'"
  # --register
  PR="$TMP/projr"; mkdir -p "$PR"; RE="$TMP/projr.env"; reset_log
  out="$(SAN_URL="$URL" SAN_ENV_FILE="$RE" "$ROOT/install.sh" --project "$PR" --register inst-1 --enrollment-token enr_goodtoken 2>&1)"; rc=$?
  [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'actif (groupe equipe)' && grep -qx 'SAN_TOKEN=agt_SECRETNEW' "$RE" && ok "install --register: enrôle après installation" || ko "install --register rc=$rc out=$out"
  printf '%s' "$out" | grep -q 'agt_SECRETNEW\|enr_goodtoken' && ko "install --register: jeton affiché" || ok "install --register: aucun jeton dans la sortie"
  check "install --register: requête register avec le jeton" req 0 "r['path']=='/api/v1/agent/register' and r['body']=={'slug':'inst-1','enrollment_token':'enr_goodtoken'}"
  rm -f "$RE"; reset_log
  printf 'enr_goodtoken\n' | SAN_URL="$URL" SAN_ENV_FILE="$RE" "$ROOT/install.sh" --project "$PR" --register inst-2 --enrollment-token - >/dev/null 2>&1
  check "install --register --enrollment-token - : stdin" req 0 "r['body'].get('enrollment_token')=='enr_goodtoken'"
  reset_log; rm -f "$RE"
  SAN_URL="$URL" SAN_ENV_FILE="$RE" "$ROOT/install.sh" --project "$PR" >/dev/null 2>&1
  [ "$(count)" = 0 ] && [ ! -e "$RE" ] && ok "install sans --register: aucun enrôlement" || ko "install sans --register"
  "$ROOT/install.sh" --project "$PR" --enrollment-token enr_x >/dev/null 2>&1; rc=$?
  [ "$rc" != 0 ] && ok "install: --enrollment-token sans --register refusé" || ko "install token seul rc=$rc"
  # agent par projet : <.claude>/san.env
  PP="$TMP/projp"; mkdir -p "$PP"; (cd "$PP" && git init -q 2>/dev/null)
  unset SAN_ENV_FILE; reset_log
  out="$(SAN_URL="$URL" "$ROOT/install.sh" --project "$PP" --register proj-p --enrollment-token enr_goodtoken 2>&1)"; rc=$?
  [ "$rc" = 0 ] && grep -qx 'SAN_TOKEN=agt_SECRETNEW' "$PP/.claude/san.env" && ok "install --register (projet): jeton dans .claude/san.env" || ko "san.env projet rc=$rc out=$out"
  [ "$(ls -l "$PP/.claude/san.env" | cut -c1-10)" = "-rw-------" ] && ok "san.env projet en 0600" || ko "droits san.env"
  grep -qxF '.claude/san.env' "$PP/.gitignore" && ok "install: .claude/san.env ajouté au .gitignore" || ko "gitignore san.env"
  "$ROOT/install.sh" --project "$PP" --force >/dev/null 2>&1
  [ "$(grep -cxF '.claude/san.env' "$PP/.gitignore")" = 1 ] && ok "install: .gitignore sans doublon" || ko "gitignore doublon"
  # le hook et bin/san installés lisent le fichier du projet (même sans SAN_ENV_FILE, avec un fichier global différent)
  mkdir -p "$G/.config/san"; printf 'SAN_URL=%s\nSAN_TOKEN=agt_GLOBAL\n' "$URL" >"$G/.config/san/agent.env"
  printf 'SAN_URL=%s\nSAN_TOKEN=agt_PROJET\n' "$URL" >"$PP/.claude/san.env"
  reset_log
  HOME="$G" "$PP/.claude/san/bin/san" state working "x" >/dev/null 2>&1
  check "bin/san installé: fichier projet prioritaire sur le global" req 0 "r['headers'].get('authorization','')=='Bearer agt_PROJET'"
  reset_log; printf '{"session_id":"pp"}' | HOME="$G" "$PP/.claude/san/hooks/stop.sh"
  check "hook installé: fichier projet prioritaire sur le global" req 0 "r['headers'].get('authorization','')=='Bearer agt_PROJET'"
  rm -f "$PP/.claude/san.env"; reset_log
  HOME="$G" "$PP/.claude/san/bin/san" state working "x" >/dev/null 2>&1
  check "bin/san installé: sans fichier projet, repli sur le global" req 0 "r['headers'].get('authorization','')=='Bearer agt_GLOBAL'"
  # dry-run
  P3="$TMP/proj3"; mkdir -p "$P3"
  "$ROOT/install.sh" --project "$P3" --dry-run >/dev/null 2>&1
  check "install --dry-run: n'écrit rien" test ! -e "$P3/.claude"
else
  echo "  (jq absent : tests d'install.sh ignorés)"
fi

echo
echo "Résultat : $pass ok, $failn échec(s)"
[ "$failn" = 0 ]
