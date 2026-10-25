#!/usr/bin/env bash
# Installe la configuration SAN pour Claude Code (hooks, skill, commande, bin/san).
#
#   ./install.sh [--project DIR | --global] [--force] [--dry-run]
#                [--register SLUG [--enrollment-token enr_…]]
#
# Sans option : installe dans le projet courant (DIR/.claude). Les hooks sont fusionnés
# dans un settings.json existant (jq requis) ; les hooks SAN déjà présents sont remplacés,
# le reste est conservé. Une sauvegarde settings.json.bak est créée.
# --register SLUG enrôle ensuite l'agent (san register) ; le jeton enr_ peut aussi venir de
# SAN_ENROLLMENT_TOKEN ou de stdin (--enrollment-token -). Nécessite SAN_URL.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mode=project target="$PWD" force=0 dry=0 reg_slug="" reg_tok=""

usage() { sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { echo "install: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --global) mode=global; shift ;;
    --project) mode=project; target="${2:-}"; [ -n "$target" ] || die "--project attend un dossier"; shift 2 ;;
    --force) force=1; shift ;;
    --dry-run) dry=1; shift ;;
    --register) reg_slug="${2:-}"; [ -n "$reg_slug" ] || die "--register attend un identifiant"; shift 2 ;;
    --enrollment-token) reg_tok="${2:-}"; [ -n "$reg_tok" ] || die "--enrollment-token attend une valeur"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "option inconnue : $1" ;;
  esac
done
[ -z "$reg_tok" ] || [ -n "$reg_slug" ] || die "--enrollment-token nécessite --register SLUG"

command -v jq >/dev/null 2>&1 || die "jq est requis pour fusionner settings.json"

if [ "$mode" = global ]; then
  claude_dir="$HOME/.claude"
else
  [ -d "$target" ] || die "dossier introuvable : $target"
  claude_dir="$(cd "$target" && pwd)/.claude"
fi
san_dir="$claude_dir/san"
san_bin="$san_dir/bin/san"
settings="$claude_dir/settings.json"

run() { if [ "$dry" = 1 ]; then echo "[dry-run] $*"; else "$@"; fi; }

# Fichier à copier ; refuse d'écraser un fichier différent sans --force.
put() { # src dst [mode]
  local src="$1" dst="$2"
  if [ -e "$dst" ] && ! cmp -s "$src" "$dst" && [ "$force" = 0 ]; then
    die "$dst existe et diffère (utiliser --force pour l'écraser)"
  fi
  run mkdir -p "$(dirname "$dst")"
  run install -m "${3:-644}" "$src" "$dst"   # pas de -D : option GNU absente de macOS
}

# Version avec substitution de @SAN_BIN@ (skill et commande).
put_subst() { # src dst
  local tmp; tmp="$(mktemp)"
  sed "s|@SAN_BIN@|$san_bin|g" "$1" >"$tmp"
  put "$tmp" "$2"; rm -f "$tmp"
}

# 1. Vérifications préalables (avant toute écriture).
if [ -e "$settings" ] && ! jq -e 'type == "object"' "$settings" >/dev/null 2>&1; then
  [ "$force" = 1 ] || die "$settings n'est pas un JSON objet valide (utiliser --force pour le remplacer)"
fi

# 2. Fichiers.
put "$SRC/bin/san" "$san_bin" 755
for f in "$SRC"/hooks/*.sh; do put "$f" "$san_dir/hooks/$(basename "$f")" 755; done
put_subst "$SRC/.claude/skills/san/SKILL.md" "$claude_dir/skills/san/SKILL.md"
put_subst "$SRC/.claude/commands/san-inbox.md" "$claude_dir/commands/san-inbox.md"

# 3. Hooks : modèle (chemins projet) adapté à la portée choisie.
new="$(cat "$SRC/settings.example.json")"
if [ "$mode" = global ]; then
  new="${new//\$CLAUDE_PROJECT_DIR\/.claude/\$HOME\/.claude}"
fi

merged="$(
  if [ -e "$settings" ] && jq -e 'type == "object"' "$settings" >/dev/null 2>&1; then base="$(cat "$settings")"; else base='{}'; fi
  jq -n --argjson base "$base" --argjson new "$new" '
    def is_san: ((.hooks // []) | any((.command // "") | contains("/san/hooks/")));
    reduce ($new.hooks | keys[]) as $ev ($base;
      .hooks[$ev] = (((.hooks[$ev] // []) | map(select(is_san | not))) + $new.hooks[$ev]))'
)"

if [ "$dry" = 1 ]; then
  echo "[dry-run] settings.json résultant :"; echo "$merged"
else
  mkdir -p "$claude_dir"
  [ -e "$settings" ] && cp -p "$settings" "$settings.bak"
  printf '%s\n' "$merged" >"$settings.tmp" && mv "$settings.tmp" "$settings"
fi

# Le fichier d'env d'un projet contient un jeton : ne jamais le versionner.
if [ "$mode" = project ] && [ "$dry" = 0 ] && git -C "$target" rev-parse --git-dir >/dev/null 2>&1; then
  gi="$(cd "$target" && pwd)/.gitignore"
  grep -qxF '.claude/san.env' "$gi" 2>/dev/null || printf '.claude/san.env\n' >>"$gi"
fi

cat <<MSG
SAN installé dans $claude_dir
  hooks   : $san_dir/hooks/
  binaire : $san_bin
MSG
if [ -z "$reg_slug" ]; then
  cat <<MSG
Configuration : exporter SAN_URL et SAN_TOKEN, ou créer $claude_dir/san.env (agent de ce projet)
ou ~/.config/san/agent.env (agent de la machine) :
  SAN_URL=https://san.example.org
  SAN_TOKEN=agt_xxx
Ou enrôler l'agent : SAN_URL=https://san.example.org $san_bin register <slug> [--enrollment-token enr_…]
Test : $san_bin state idle "test"
MSG
fi

# 4. Enrôlement facultatif.
if [ -n "$reg_slug" ]; then
  if [ "$dry" = 1 ]; then
    echo "[dry-run] $san_bin register $reg_slug"
  else
    # Le jeton enr_ passe par l'environnement du processus, jamais par un argument.
    if [ "$reg_tok" = - ]; then IFS= read -r reg_tok || true; fi
    # Projet : le jeton va dans <.claude>/san.env (un agent par projet, lu en priorité par bin/san et
    # les hooks) ; global : fichier ~/.config/san/agent.env. SAN_ENV_FILE explicite prime.
    if [ "$mode" = project ] && [ -z "${SAN_ENV_FILE:-}" ]; then export SAN_ENV_FILE="$claude_dir/san.env"; fi
    SAN_ENROLLMENT_TOKEN="${reg_tok:-${SAN_ENROLLMENT_TOKEN:-}}" "$san_bin" register "$reg_slug" \
      || echo "install: l'enrôlement a échoué (voir ci-dessus) ; relancer : $san_bin register $reg_slug" >&2
  fi
fi
