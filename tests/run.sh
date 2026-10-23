#!/usr/bin/env bash
# Tests de bin/san, des hooks, de install.sh et du faux agent contre un mock server.
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
check "Notification -> state waiting" req 0 "r['path']=='/api/v1/agent/state' and r['body']['status']=='waiting' and r['body']['ttl_s']>0 and $AUTH"
check "Notification -> nudge high" req 1 "r['path']=='/api/v1/agent/nudge' and r['body']['priority']=='high' and 'permission' in r['body']['text'] and $AUTH"
reset_log
run_hook post-tool-use "{$S,\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"a.ts\"}}" >/dev/null
[ "$(count)" = 1 ] && ok "après waiting: le throttling est levé" || ko "throttle après waiting"
reset_log
run_hook notification "{$S,\"notification_type\":\"auth_success\",\"message\":\"ok\"}" >/dev/null
[ "$(count)" = 0 ] && ok "Notification auth_success ignorée" || ko "auth_success non ignorée"

reset_log
run_hook stop "{$S,\"hook_event_name\":\"Stop\",\"stop_hook_active\":false}" >/dev/null
check "Stop -> state done" req 0 "r['path']=='/api/v1/agent/state' and r['body']['status']=='done' and r['body']['ttl_s']>0 and $AUTH"
check "Stop -> nudge « Tâche terminée » (normal)" req 1 "r['path']=='/api/v1/agent/nudge' and r['body']=={'text':'Tâche terminée'} and $AUTH"

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

echo "== hooks : non configuré / serveur injoignable / entrée vide"
for h in session-start user-prompt-submit post-tool-use notification stop session-end; do
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
for h in session-start user-prompt-submit post-tool-use notification stop session-end; do
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
check "fake-agent: états working/waiting/error/done publiés" python3 -I -c '
import json,sys
rs=[json.loads(l) for l in open(sys.argv[1])]
st={r["body"]["status"] for r in rs if r["path"].endswith("/state")}
assert {"idle","working","waiting","error","done"} <= st, st
assert any(r["path"].endswith("/say") for r in rs)
assert any(r["path"].endswith("/nudge") and r["body"].get("priority")=="high" for r in rs)
assert any(r["path"].endswith("/inbox") for r in rs)
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
  check "install: 6 événements SAN" jq -e '[.hooks|keys[]] | (index("SessionStart")!=null and index("UserPromptSubmit")!=null and index("PostToolUse")!=null and index("Notification")!=null and index("Stop")!=null and index("SessionEnd")!=null)' "$P/.claude/settings.json"
  "$ROOT/install.sh" --project "$P" >/dev/null 2>&1
  check "install idempotent (pas de doublon)" jq -e '(.hooks.Stop|length)==2' "$P/.claude/settings.json"
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
