# SAN_agent-claude_code

Configuration **Claude Code** qui transforme une session en *agent* du système SAN
(afficheur d'état des agents : carte M5Stick S3 et application web). Elle publie
automatiquement l'état de la session (hooks), permet à Claude de prévenir l'utilisateur
(nudge, message vocal) et de lire les messages vocaux reçus (skill). Tout passe par
`curl` ; aucune dépendance autre que bash et curl (`jq` est optionnel, sauf pour `install.sh`).

Référence de l'API : `SAN/docs/SPEC.md` §10.1.

## Contenu

| Chemin | Rôle |
|---|---|
| `bin/san` | Client en ligne de commande de l'API agent |
| `hooks/*.sh` | Hooks Claude Code (un script par événement + `_lib.sh`) |
| `settings.example.json` | Exemple de configuration des hooks |
| `.claude/skills/san/SKILL.md`, `.claude/commands/san-inbox.md` | Skill et commande `/san-inbox` |
| `install.sh` | Installation dans un projet ou en global |
| `tools/fake-agent.sh` | Faux agent de démonstration |
| `tests/` | Mock server (Python) et `tests/run.sh` |

## Installation

```sh
./install.sh --project /chemin/vers/mon/projet   # installe dans <projet>/.claude
./install.sh --global                             # installe dans ~/.claude
```

L'installeur (qui requiert `jq`) copie `bin/san` et les hooks dans `.claude/san/`, la
skill dans `.claude/skills/san/`, la commande dans `.claude/commands/`, et **fusionne**
les hooks dans `.claude/settings.json` : les hooks et réglages existants sont conservés,
les hooks SAN déjà installés sont remplacés (idempotent), une sauvegarde
`settings.json.bak` est créée. Il refuse de remplacer un `settings.json` invalide ou une
skill/commande modifiée sans `--force`. `--dry-run` affiche le résultat sans rien écrire.

Sans installeur : copier `settings.example.json` dans `.claude/settings.json` et adapter
les chemins (`$CLAUDE_PROJECT_DIR/.claude/san/hooks/…`) vers `hooks/` de ce dépôt.

## Configuration

1. Dans l'interface d'administration SAN, **créer un agent** (nom, identifiant) puis
   **générer son jeton** : `agt_…`. Il n'est affiché qu'une fois (régénérable).
2. Donner à `bin/san` l'URL du serveur (sans `/api/v1`, il est ajouté) et le jeton, par
   variables d'environnement :

   ```sh
   export SAN_URL=https://san.example.org
   export SAN_TOKEN=agt_xxx
   ```

   ou par le fichier `~/.config/san/agent.env` (`chmod 600`), lu sans être exécuté :

   ```sh
   SAN_URL=https://san.example.org
   SAN_TOKEN=agt_xxx
   ```

   L'environnement prime sur le fichier. Variables facultatives : `SAN_STRICT=1`
   (codes de retour réels), `SAN_DEBUG=1` (messages sur stderr), `SAN_CONNECT_TIMEOUT`
   (2 s), `SAN_MAX_TIME` (5 s).

**Non bloquant** : si `SAN_URL`/`SAN_TOKEN` manquent ou si le serveur est injoignable ou
refuse le jeton, `san` ne dit rien et sort avec le code 0 (timeouts courts). Seules les
erreurs d'usage (arguments invalides) donnent le code 2. Les hooks sortent toujours en 0
et n'écrivent rien sur stdout (celui de `SessionStart`/`UserPromptSubmit` est injecté
dans le contexte de Claude).

## Ce que publient les hooks

| Événement Claude Code | État SAN | Détails |
|---|---|---|
| `SessionStart` | `idle` « Session démarrée » | ttl 1800 s |
| `UserPromptSubmit` | `working` | detail = début du prompt, 60 caractères max, secrets masqués (jetons, `password=…`, longues chaînes opaques) ; ttl 900 s |
| `PostToolUse` | `working` | detail « Edit foo.ts » (nom de fichier sans chemin ; pour `Bash`, seulement le premier mot de la commande) ; au plus un appel toutes les 10 s (`SAN_TOOL_THROTTLE_S`) ; ttl 900 s |
| `Notification` (`permission_prompt`, `idle_prompt`, `elicitation_dialog`) | `waiting` + nudge `high` | texte = message de la notification (80 car. max) ; ttl 1800 s |
| `Stop` | `done` « Tâche terminée » + nudge normal « Tâche terminée » | ttl 3600 s |
| `SessionEnd` | `idle` « Session terminée » | ttl 300 s |

Les TTL font passer l'état en `stale` côté serveur si la session meurt sans `SessionEnd`.
Les appels partent en arrière-plan pour ne pas ralentir Claude Code
(`SAN_HOOK_SYNC=1` pour les rendre synchrones). Les TTL se règlent par `SAN_TTL_WORKING`,
`SAN_TTL_WAITING`, `SAN_TTL_IDLE`, `SAN_TTL_DONE`, `SAN_TTL_ENDED`.

La skill `san` (chargée automatiquement par Claude quand c'est pertinent) lui apprend à
prévenir l'utilisateur par `say` quand une validation est requise et à consulter l'inbox ;
`/san-inbox` consulte l'inbox à la demande. Le serveur ne fait pas de transcription : un
message vocal reçu est un fichier audio que Claude ne peut pas écouter sans outil dédié.

## Usage manuel

```sh
san state working "Migration" --progress 40 --ttl 900   # idle|working|waiting|error|done
san nudge "Validation requise" --high
san say "J'ai terminé."                                  # message vocal (TTS serveur)
san voice message.wav                                    # envoi d'un fichier audio (wav, mp3, ogg)
san inbox --wait 30 --ack 812                            # long-poll, acquitte avant lecture
san fetch-voice c_01J… --format mp3 -o message.mp3
```

`inbox` affiche le JSON du serveur (`--pretty` : une ligne par événement, avec `jq`).

## Faux agent de démonstration

```sh
SAN_URL=https://san.example.org SAN_TOKEN=agt_xxx tools/fake-agent.sh --interval 3
tools/fake-agent.sh --once --interval 1
```

Il rejoue en boucle : `idle`, `working` avec progression, `waiting` + nudge `high` + `say`,
lecture de l'inbox (avec acquittement), `error`, puis `done`. `Ctrl-C` repasse l'agent en `idle`.

## Tests

```sh
tests/run.sh          # mock server Python (stdlib) + vérification de bin/san, hooks, install.sh, faux agent
shellcheck bin/san hooks/*.sh install.sh tools/*.sh tests/run.sh
```

Le mock enregistre chaque requête (méthode, chemin, en-têtes, corps) ; les tests vérifient
chemin, méthode, `Authorization`, JSON valide, et le comportement non configuré / serveur
injoignable (code 0, rapide, silencieux). La CI GitHub (`.github/workflows/ci.yml`) lance les deux.
