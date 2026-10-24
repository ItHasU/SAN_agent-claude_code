#!/usr/bin/env bash
# Installe la configuration SAN pour Claude Code (hooks, skill, commande, bin/san).
#
#   ./install.sh [--project DIR | --global] [--force] [--dry-run]
#
# Sans option : installe dans le projet courant (DIR/.claude). Les hooks sont fusionnés
# dans un settings.json existant (jq requis) ; les hooks SAN déjà présents sont remplacés,
# le reste est conservé. Une sauvegarde settings.json.bak est créée.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mode=project target="$PWD" force=0 dry=0

usage() { sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { echo "install: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --global) mode=global; shift ;;
    --project) mode=project; target="${2:-}"; [ -n "$target" ] || die "--project attend un dossier"; shift 2 ;;
    --force) force=1; shift ;;
    --dry-run) dry=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "option inconnue : $1" ;;
  esac
done

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
  run install -D -m "${3:-644}" "$src" "$dst"
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

cat <<MSG
SAN installé dans $claude_dir
  hooks   : $san_dir/hooks/
  binaire : $san_bin
Configuration : exporter SAN_URL et SAN_TOKEN, ou créer ~/.config/san/agent.env :
  SAN_URL=https://san.example.org
  SAN_TOKEN=agt_xxx
Test : $san_bin state idle "test"
MSG
