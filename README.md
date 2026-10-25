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

## Démarrage rapide (enrôlement automatique)

1. Côté admin SAN : créer un **jeton d'enrôlement** (`enr_…`) lié à un groupe d'agents.
2. Sur la machine de l'agent :

   ```sh
   export SAN_URL=https://san.example.org
   export SAN_ENROLLMENT_TOKEN=enr_xxx          # ou : echo enr_xxx | san register mon-agent --enrollment-token -
   ./install.sh --global --register mon-agent   # ou : san register mon-agent --enrollment-token enr_xxx
   ```

   `san register <slug> [--name NOM] [--enrollment-token enr_…|-] [--force]` appelle
   `POST /agent/register` et écrit `SAN_TOKEN` (et `SAN_URL` s'il manque) dans
   `~/.config/san/agent.env` (`SAN_ENV_FILE`, `chmod 600`) sans toucher aux autres variables.
   Il refuse d'écraser un `SAN_TOKEN` existant sauf avec `--force`. Les jetons `agt_`/`enr_`
   ne sont jamais affichés ; le jeton d'enrôlement est transmis sur stdin à curl (pas visible
   dans `ps`), préférer `SAN_ENROLLMENT_TOKEN` ou `--enrollment-token -` à l'argument.
3. Sans jeton d'enrôlement, l'agent est **en attente** : un administrateur doit l'approuver.
   `san register --status` affiche `pending` ou `active` (« rejeté ou révoqué » si l'agent a été
   rejeté, purgé ou révoqué). Tant qu'il est `pending`, le serveur répond `403 agent_pending` :
   `san` et les hooks restent silencieux (code 0) ; avec `SAN_DEBUG=1`, un message renvoie vers
   `san register --status`.

Codes de retour de `register` : 0 si actif ou en attente ; 1 sinon (jeton d'enrôlement invalide,
slug déjà pris, trop de demandes, serveur injoignable…) avec un message en français ; 2 pour un usage invalide.

## Configuration manuelle

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
| `UserPromptSubmit` | `working` (réflexion), **aucun son** (+ nudge `start` « Début du travail » envoyé avant l'état si `SAN_NUDGE_START=1`) | detail = début du prompt, 60 caractères max, secrets masqués (jetons, `password=…`, longues chaînes opaques) ; ttl 900 s. Nudge `start` : désactivé par défaut, un seul par tour de travail (voir ci-dessous) |
| `PostToolUse` | `working` | detail « Edit foo.ts » (nom de fichier sans chemin ; pour `Bash`, seulement le premier mot de la commande) ; au plus un appel toutes les 10 s (`SAN_TOOL_THROTTLE_S`) ; ttl 900 s |
| `Notification` (`permission_prompt`, `elicitation_dialog`) | nudge `question` (`high`) **seul**, sans `state` | texte = message de la notification (80 car. max). `idle_prompt` est ignoré (doublon sonore après `Stop`, écraserait « prêt ») |
| `Stop` | `done` « Tâche terminée » + nudge `done` (priorité normale) « Tâche terminée » | ttl 3600 s. **Si des sous-agents sont actifs** : ni `done` ni nudge, mais `working` « N sous-agent(s) en cours » (ttl 900 s) |
| `SubagentStart` / `SubagentStop` | rien (tenue du compteur de sous-agents actifs) | voir ci-dessous |
| `StopFailure` (tour terminé sur erreur d'API) | `error` « Erreur : <type> » + nudge `error` (`high`) | `<type>` = champ `error` du hook (`rate_limit`, `overloaded`, `authentication_failed`…), sinon « Erreur » ; ttl 1800 s (`SAN_TTL_ERROR`) |
| `SessionEnd` | `idle` « Session terminée » | ttl 300 s |

`SessionStart` n'envoie pas de nudge.

**Carte M5StickS3** : plus de file de notifications ni d'acquittement. Chaque agent y a une
icône = dernier statut reçu (coche verte = prêt/terminé, `!` = problème, `?` = question,
animation = réflexion) et une pastille de vocaux en attente. La carte sélectionne
automatiquement l'agent dont le statut ou les vocaux changent (vocal > question > problème >
prêt ; « réflexion » ne déclenche rien, rien non plus pendant un enregistrement) et peut lire
les vocaux automatiquement (réglage « lecture auto », oui par défaut).

**Type de nudge = son et statut** : le `type` détermine le son (marimba, un seul par événement
important) et, côté serveur SAN, le statut affiché : `question` -> `?`, `error` -> `!`,
`done` -> coche verte ; `state working` -> réflexion. Les hooks respectent cette règle sans
doublon : `Notification` n'envoie que le nudge `question` (un `state` avant ou après ferait
flasher une icône intermédiaire ou écraserait `?`) ; `Stop` et `StopFailure` envoient l'état
puis le nudge, tous deux vers la même icône. Le serveur peut ajuster cette correspondance.

**Sous-agents** : les événements `SubagentStart` / `SubagentStop` (champs `agent_id`, `agent_type`)
alimentent un registre par session dans `SAN_STATE_DIR` (`<session>.subagents`, une ligne
`agent_id epoch` ; écriture atomique par fichier temporaire + `mv` sous verrou `mkdir`).
`Stop` lit d'abord le tableau `background_tasks` de son entrée (documenté : une entrée par tâche
en cours ; le nombre de sous-agents actifs = entrées `type == "subagent"` dont le `status` n'est
pas terminal : completed, failed, killed, cancelled, stopped…, la doc ne listant pas les valeurs).
Quand cette clé est présente (même vide), elle fait autorité, y compris si `SubagentStop` ne se
déclenche pas pour un sous-agent d'arrière-plan, et un résultat 0 vide le registre. Le registre
n'est qu'un repli (clé absente sur d'anciennes versions, ou `jq` absent). Il donne le nombre de sous-agents actifs : s'il est > 0, l'agent principal n'est pas
« terminé » et SAN reçoit `working` au lieu de `done` + nudge. Le `Stop` du tour final, une
fois les sous-agents finis, publie `done` normalement. Garde-fous :

- un `SubagentStop` pour un `agent_id` inconnu est ignoré (Claude Code lance aussi des agents
  internes, p. ex. suggestions de prompt ou `/btw`, qui déclenchent `SubagentStop`) : le compteur ne descend jamais sous 0 ;
- (repli seulement) une entrée de plus de 2 h (`SAN_SUBAGENT_MAX_AGE_S`, 7200 par défaut) est ignorée (compteur « fantôme » si un `SubagentStop` s'est perdu) ;
- `SessionStart`, `SessionEnd` et `StopFailure` vident le registre.

Cas limite : si l'agent principal s'est déjà arrêté (`Stop` publié en `working` à cause d'un
sous-agent d'arrière-plan) et que le dernier sous-agent finit sans qu'aucun nouveau tour ne
démarre, `SubagentStop` n'envoie rien : aucun `done` n'est inventé et l'état reste `working`
jusqu'à l'expiration de son TTL (900 s, puis `stale` côté serveur) ou jusqu'au prochain tour.

**Nudge `start`** : `SAN_NUDGE_START=1` (environnement ou `~/.config/san/agent.env` ; défaut `0`,
désactivé) envoie `san nudge --type start` au début d'un tour. Pour limiter le bruit, il n'est
envoyé que si le dernier état `working` local date de plus de 300 s (`SAN_NUDGE_START_WINDOW_S`)
ou a été réinitialisé par `Stop`, `StopFailure`, `Notification` ou `SessionStart` : un seul
nudge par tour de travail, pas un par prompt enchaîné.

**`PostToolUseFailure` volontairement non branché** : un outil qui échoue est un événement
courant et bénin (commande en erreur, fichier absent) que Claude traite lui-même ; l'événement
serait trop bavard. Seul `StopFailure` (le tour s'arrête réellement sur une erreur d'API) publie `error`.
`error` reste aussi disponible via la skill ou `san nudge --type error`.

Les TTL font passer l'état en `stale` côté serveur si la session meurt sans `SessionEnd`.
Les appels partent en arrière-plan pour ne pas ralentir Claude Code
(`SAN_HOOK_SYNC=1` pour les rendre synchrones). Les TTL se règlent par `SAN_TTL_WORKING`,
`SAN_TTL_IDLE`, `SAN_TTL_DONE`, `SAN_TTL_ERROR`, `SAN_TTL_ENDED`.

Un `say` publié par l'agent apparaît sur la carte comme vocal en attente (pastille) et peut
être lu automatiquement.

La skill `san` (chargée automatiquement par Claude quand c'est pertinent) lui apprend à
prévenir l'utilisateur par `say` quand une validation est requise et à consulter l'inbox ;
`/san-inbox` consulte l'inbox à la demande. Le serveur ne fait pas de transcription : un
message vocal reçu est un fichier audio que Claude ne peut pas écouter sans outil dédié.

## Usage manuel

```sh
san state working "Migration" --progress 40 --ttl 900   # idle|working|waiting|error|done (pour une question, préférer le nudge question)
san nudge "Validation requise" --type question --high   # types : start|notification|question|done|error
san say "J'ai terminé."                                  # message vocal (TTS serveur)
san voice message.wav                                    # envoi d'un fichier audio (wav, mp3, ogg)
san inbox --wait 30 --ack 812                            # long-poll, acquitte avant lecture
san fetch-voice c_01J… --format mp3 -o message.mp3
san register mon-agent --enrollment-token enr_xxx        # enrôlement (voir Démarrage rapide)
san register --status                                    # pending | active
```

Le type de nudge (`--type`) est facultatif ; sans lui le champ n'est pas envoyé et le
serveur applique `notification`. Une valeur inconnue est refusée côté client (code 2).

`inbox` affiche le JSON du serveur (`--pretty` : une ligne par événement, avec `jq`).

## Faux agent de démonstration

```sh
SAN_URL=https://san.example.org SAN_TOKEN=agt_xxx tools/fake-agent.sh --interval 3
tools/fake-agent.sh --once --interval 1
```

Il rejoue en boucle (types de nudge `question`, `error`, `done`, défaut) : `idle`, `working` avec progression, nudge `question` `high` + `say`,
lecture de l'inbox (avec acquittement), `error`, puis `done`. `Ctrl-C` repasse l'agent en `idle`.

## Tests

```sh
tests/run.sh          # mock server Python (stdlib) + vérification de bin/san, hooks, install.sh, faux agent
shellcheck bin/san hooks/*.sh install.sh tools/*.sh tests/run.sh
```

Le mock enregistre chaque requête (méthode, chemin, en-têtes, corps) ; les tests vérifient
chemin, méthode, `Authorization`, JSON valide, et le comportement non configuré / serveur
injoignable (code 0, rapide, silencieux). La CI GitHub (`.github/workflows/ci.yml`) lance les deux.
