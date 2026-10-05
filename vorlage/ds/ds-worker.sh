#!/usr/bin/env bash
# DeepSeek als Arbeiter: fuehrt einen ausformulierten Auftrag in einem eigenen
# git-Worktree aus (Claude Code headless, Backend DeepSeek). Auftraggeber und
# Reviewer ist die Claude-Sitzung im Haupt-Checkout. Projektanpassung: ds/projekt.sh.
#
#   ds/ds-worker.sh start      <name>   # ds/arbeit/<name>.auftrag.md ausfuehren
#   ds/ds-worker.sh budget     <name>   # Lesebudget des Auftrags (Token je genannter Datei)
#   ds/ds-worker.sh plan       <name>   # Plan-Modus 1: nur lesen, Plan -> <name>.plan.md
#   ds/ds-worker.sh form       <name>   # Plan-Modus: Formpruefung des Plans (ds/plan.py)
#   ds/ds-worker.sh bauen      <name>   # Plan-Modus 2: Auftrag + Plan + <name>.freigabe.md
#   ds/ds-worker.sh teilen     <name>   # Plan-Modus: je Paket <name>-pN.auftrag.md (dann start)
#   ds/ds-worker.sh nacharbeit <name>   # ds/arbeit/<name>.nacharbeit.md (Sitzung fortgesetzt
#                                       # oder, bei grossem Kontext, frisch mit Staffelstab)
#   ds/ds-worker.sh diff       <name>   # Aenderungen des Arbeiters zeigen
#   ds/ds-worker.sh uebernehmen <name>  # Aenderungen in den Haupt-Checkout (ohne Commit)
#   ds/ds-worker.sh verwerfen  <name>   # Worktree + Zweig wegwerfen
#   ds/ds-worker.sh tokens     <name>   # Token + Kosten: Opus, Bauleiter, DeepSeek (ds/tokens.py)
#   ds/ds-worker.sh pruefen    <name> [--haupt]  # Abnahmebefehle des Auftrags, nur gruen/ROT
#   ds/ds-worker.sh warte      <name>   # blockiert bis Laufende (max DS_WARTE s, 570)
#
# Zugang: ~/.config/deepseek/env mit DEEPSEEK_API_KEY=... (nie ins Repo).
# DS_MODEL ueberschreibt das Modell (Standard deepseek-flash).
# Abbruch (Exit 3): ein Modell kann haengen und nur SSE-Keep-alives schicken,
# dann greift kein Timeout. Vorabprobe: erstes Token binnen DS_PROBE s (45).
# Watchdog: still beim Warten auf die API DS_API_STILL s (90), waehrend ein
# Werkzeug laeuft DS_STILL s (300), gesamt DS_MAX s (3600).
# Lage: https://status.deepseek.com
# Zuege: Notbremse --max-turns DS_ZUEGE_MAX (250), Richtwert im Rollen-Prompt
# DS_ZUEGE_RICHT (150). DS_EFFORT (low|medium|high|max) setzt --effort, sonst
# Modellstandard -- fuer A/B-Messungen. Nach jedem Edit prueft der Hook
# ds/arbeiter-pruef.sh die Datei (nach_edit in ds/projekt.sh).
# Etappen statt Compaction: waechst der Kontext ueber DS_KONTEXT Token (110000),
# endet die Sitzung an der naechsten Werkzeuggrenze und eine frische Sitzung
# macht weiter (Staffelstab: Auftrag/Plan/Freigabe woertlich, Diff-Stand,
# Aufgabenliste); hoechstens DS_ETAPPEN (4) Etappen je Lauf. Grund: Claude Code
# fasst sonst bei ~150k automatisch zusammen und kann dabei Freigabe-Korrekturen
# verlieren (Plan-Modus-Test tempo-v7, 2026-10-04: zwei Compactions).
# Endet eine Etappe ohne neue Aenderung im Worktree, startet keine gleiche
# Etappe mehr (sie wuerde dasselbe erneut lesen; ui-zusammenbau 2026-10-05):
# erst Vorerkundung, beim zweiten Mal Exit 6 (zu gross). Etappengrenze: Exit 6.
# Lesebudget: start schaetzt die Token der im Auftrag genannten Dateien
# (ds/plan.py budget, ganz gelesen; (Bytes + 7*Zeilen) / DS_ZEICHEN_JE_TOKEN,
# kalibriert an 404 Read-Ergebnissen: 2,66). Ueber DS_LESEBUDGET Token
# (Standard DS_KONTEXT/2) erkundet zuerst eine Nur-Lese-Sitzung mit der
# Planer-Rolle vor und schreibt eine Lagekarte (Fundstellen, Schnittstellen,
# Reihenfolge -- keine Entscheidungen, die stehen im Auftrag); gebaut wird mit
# Auftrag + Lagekarte. DS_VORERKUNDUNG=auto|immer|aus.
# Exit-Codes: 0 fertig, 1 Fehler/Verweigerung, 3 Abbruch (Watchdog/Modell),
# 5 Planform fehlerhaft, 6 zu gross fuer eine Sitzung (teilen oder Plan-Modus).
# Plan-Modus: Richtwert DS_PLAN_ZUEGE (60), Grenze DS_PLAN_ZUEGE_MAX (100),
# hoechstens DS_PAKETE (4) Pakete im Schnitt.
# Braucht: bash >= 4.4, git, jq, curl, python3, pgrep, GNU stat/tac/realpath, claude (CLI).
set -euo pipefail

REPO=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
ARBEIT="$REPO/ds/arbeit"
WT_BASIS="$(dirname "$REPO")/$(basename "$REPO")-ds"
MODEL=${DS_MODEL:-deepseek-flash}
STILL_MAX=${DS_STILL:-300}
API_STILL_MAX=${DS_API_STILL:-90}
PROBE_MAX=${DS_PROBE:-45}
LAUF_MAX=${DS_MAX:-3600}
WARTE_MAX=${DS_WARTE:-570}
ZUEGE_MAX=${DS_ZUEGE_MAX:-250}
ZUEGE_RICHT=${DS_ZUEGE_RICHT:-150}
KONTEXT_MAX=${DS_KONTEXT:-110000}
ETAPPEN_MAX=${DS_ETAPPEN:-4}
PLAN_ZUEGE_RICHT=${DS_PLAN_ZUEGE:-60}
PLAN_ZUEGE_MAX=${DS_PLAN_ZUEGE_MAX:-100}
LESEBUDGET=${DS_LESEBUDGET:-$(( KONTEXT_MAX / 2 ))}
VORERKUNDUNG=${DS_VORERKUNDUNG:-auto}
export DS_PAKETE=${DS_PAKETE:-4} DS_ZEICHEN_JE_TOKEN=${DS_ZEICHEN_JE_TOKEN:-2.66}

DS_ERLAUBT=(); DS_NUR_LESEN=(memory); DS_KOPIEREN=(); DS_FEHLERMUSTER=()
DS_HINWEIS_PRUEFEN='Pruefe deine Arbeit mit den Befehlen unter "## Abnahme" im Auftrag.'
vor_pruefen() { :; }
[[ -r $REPO/ds/projekt.sh ]] && . "$REPO/ds/projekt.sh"
mkdir -p "$ARBEIT"

cmd=${1:-}; name=${2:-}
[[ -n $cmd && -n $name ]] || { sed -n 6,20p "$0"; exit 2; }
[[ $name =~ ^[a-z0-9-]+$ ]] || { echo "Name nur a-z, 0-9, -" >&2; exit 2; }
WT="$WT_BASIS/$name"
ZWEIG="ds/$name"

# Rolle des Arbeiters; ergaenzt CLAUDE.md, das er im Worktree selbst liest.
# Werkzeug-Regeln aus der Zugauswertung 2026-10-04: 4-12 abgelehnte Befehle
# je Lauf mit 1-5 Umformulierungen, cd-Irrwege, kaum parallele Aufrufe.
ERLAUBT_TEXT=$(printf '%s\n' "${DS_ERLAUBT[@]}" 'Bash(git status:*)' 'Bash(git diff:*)' \
  'Bash(git log:*)' 'Bash(ls:*)' 'Bash(grep:*)' |
  sed -e 's/^Bash(//' -e 's/:\*)$//' -e 's/)$//' | paste -sd ',' | sed 's/,/, /g')
ROLLE="Du bist der Arbeiter (DeepSeek) in diesem Projekt. Ein Claude-Opus-Auftraggeber
hat dir einen Auftrag ausformuliert und reviewt dein Ergebnis.
- Halte dich eng an den Auftrag: nur die genannten Dateien/Grenzen, kein Umbau nebenbei.
- Nur LESEN: ${DS_NUR_LESEN[*]}. Gedaechtnis-/Dokupflege macht der Auftraggeber;
  Erkenntnisse gehoeren in deinen Bericht.
- Nicht committen, nicht pushen, keine git-Zweige wechseln.
Werkzeuge (jede Ablehnung kostet Zuege):
- Dein Arbeitsverzeichnis ist die Wurzel deines Worktrees; jeder Befehl laeuft
  von dort mit relativen Pfaden. Kein cd, kein git -C, keine absoluten Pfade.
- Bash: genau EIN Befehl je Aufruf -- kein ; && ||, kein \$(...), keine
  Heredocs, kein python/node/sed -i. Freigegeben sind nur: $ERLAUBT_TEXT.
  Wird etwas abgelehnt, NICHT umformulieren: Read/Grep/Edit nehmen oder es im
  Bericht unter Offen nennen. Rechnen (Tabellen, Konstanten) im Code oder Test.
- Suchen mit Grep, lesen mit Read und offset/limit (~150 Zeilen um die
  Fundstelle); Dateien ueber ~300 Zeilen nie ganz. Unabhaengige Such- und
  Leseschritte buendelst du in EINER Antwort (mehrere Tool-Aufrufe zugleich).
Vorgehen:
- Starte bei den Einstiegsstellen aus dem Auftrag (oder der Lagekarte);
  erkunde nur, was der naechste Schritt braucht.
- Lege frueh eine Aufgabenliste mit TodoWrite an, je Punkt die Fundstellen
  (datei:zeile), und halte sie aktuell. Sie ist dein Staffelstab: bei grossem
  Kontext macht eine frische Sitzung mit genau dieser Liste weiter.
- Baue in Teilschritten (ein Vertrag, eine Funktion, ein Test). Nach jedem
  Edit prueft ein Hook die Datei und haengt Fehler an: sofort beheben, ausser
  sie stammen erkennbar von einem noch offenen Teil desselben Teilschritts.
- Nach jedem Teilschritt gezielt testen, nicht erst am Ende. $DS_HINWEIS_PRUEFEN
  Die ganze Abnahme einmal am Ende.
- Richtwert ${ZUEGE_RICHT} Tool-Aufrufe, harte Grenze ${ZUEGE_MAX}. Wird es
  deutlich mehr, ist der Auftrag zu gross: fertigen Teil gruen machen, Bericht
  'teilweise' mit dem Rest.
- Kannst du etwas nicht klaeren, triff keine Designentscheidung: halte an und frage im Bericht.
Deine LETZTE Antwort ist der Bericht, genau in dieser Form (Markdown):
## Ergebnis
erledigt | teilweise | blockiert -- ein Satz
## Aenderungen
- <datei>: was und warum
## Pruefung
- <befehl>: Ergebnis (gruen/rot, bei rot die Fehlerzeile)
## Offen / Fragen
- ... (oder \"keine\")
## Erkenntnisse fuers Gedaechtnis
- ... (oder \"keine\")"

# Rolle in der Planphase (plan): nur lesen, Plan in fester Gliederung. Opus
# prueft ihn ohne Code; ds/plan.py prueft die Form. Zugzahlen schaetzt der
# Planer nicht (Test tempo-v7: ~52 geschaetzt, 315 gebraucht).
PLAN_ROLLE="Du bist der Planer (DeepSeek) in diesem Projekt. Ein Claude-Opus-Auftraggeber
hat Ziel und Leitplanken vorgegeben und prueft deinen Plan, OHNE Code zu lesen.
Du hast nur Lese-Werkzeuge und aenderst nichts.
- Dein Arbeitsverzeichnis ist die Worktree-Wurzel; relative Pfade.
- Gezielt erkunden: Grep, dann Read mit offset/limit (~80 Zeilen um die
  Fundstelle), nie ganze grosse Dateien. Unabhaengige Such- und Leseschritte
  buendelst du in EINER Antwort. Richtwert ${PLAN_ZUEGE_RICHT} Tool-Aufrufe, Grenze ${PLAN_ZUEGE_MAX}.
- Leitplanken sind entschieden. Was sie offen lassen und du festlegst, steht
  sichtbar unter Entscheidungen; echte Designfragen unter Offene Fragen.
- Keine Zugzahlen oder Aufwaende schaetzen.
Deine LETZTE Antwort ist der Plan, ohne Vorrede, genau mit diesen Abschnitten:
## Befunde
- \`datei:zeile\` -- was dort passiert -- was sich aendert
## Alle Leser
Je Gruppe der Grep-Befehl, dann die Dateien, die einen geaenderten Vertrag
(Signatur, Format, Konstante, Bedeutung) lesen oder schreiben -- auch Tests,
Tools, Doku, andere Sprachen.
## Entscheidungen
- Entscheidung: X, weil Y
## Offene Fragen
- ... (oder \"keine\")
## Randfaelle
- Fall -> erwartetes Verhalten -> Test, der es prueft
## Schnitt
- P1 <kurzname> | Aendern: <datei>, <datei> | nach: -
  Abnahme: <befehl>
(je Paket eine Zeile wie oben, darunter je Abnahmebefehl eine Zeile \"  Abnahme: ...\").
Hoechstens ${DS_PAKETE} Pakete mit disjunkten Dateien; jedes Paket ist ein allein
testbarer Teil, keine Mini-Pakete. Kleiner Auftrag: genau ein Paket P1.
Abhaengigkeiten als \"nach: P1\" (das Paket baut auf dem uebernommenen P1 auf)."

# Rolle der Vorerkundung (lage): Planer-Werkzeuge, aber der Auftrag ist schon
# entschieden. Ergebnis ist eine Lagekarte, mit der der Arbeiter nur noch die
# Fundstellen liest statt ganzer Dateien (Lesebudget ueber DS_LESEBUDGET).
LAGE_ROLLE="Du bist der Erkunder (DeepSeek) in diesem Projekt. Der Auftrag unten ist
fertig entschieden; ein Arbeiter baut ihn nach dir in einer frischen Sitzung
mit kleinem Kontext. Deine Lagekarte erspart ihm das Lesen ganzer Dateien.
Du hast nur Lese-Werkzeuge und aenderst nichts.
- Dein Arbeitsverzeichnis ist die Worktree-Wurzel; relative Pfade.
- Gezielt erkunden: Grep -n, dann Read mit offset/limit (~80 Zeilen um die
  Fundstelle), nie ganze grosse Dateien. Unabhaengige Such- und Leseschritte
  buendelst du in EINER Antwort. Richtwert ${PLAN_ZUEGE_RICHT} Tool-Aufrufe, Grenze ${PLAN_ZUEGE_MAX}.
- Nur Fakten, keine Entscheidungen: was der Auftrag offen laesst, steht unter
  Luecken. Keine Zugzahlen oder Aufwaende schaetzen.
- Zeilenangaben exakt (datei:von-bis), damit der Arbeiter genau dort liest.
Deine LETZTE Antwort ist die Lagekarte, ohne Vorrede, hoechstens ~150 Zeilen,
genau mit diesen Abschnitten:
## Fundstellen
- \`datei:von-bis\` -- was dort steht -- was der Auftrag dort aendert
## Schnittstellen
- \`datei:zeile\` \`signatur/signal/konstante\` -- Bedeutung (was der Arbeiter
  aufruft oder nachahmt, ohne die Datei lesen zu muessen)
## Alle Leser
Je Gruppe der Grep-Befehl, dann die Fundstellen \`datei:zeile\`.
## Reihenfolge
1. Teilschritt -- Dateien -- gezielter Test danach
## Luecken
- was der Auftrag nicht festlegt oder was nicht zum Code passt (oder \"keine\")"

MODUS=bau   # bau | plan | lage (starte_claude)

starte_claude() {  # $1 Prompt-Datei, weitere Argumente an claude
  # Nur im Hintergrund aufrufen (laufe): cd + exec ersetzen die Subshell durch
  # claude, damit $! die PID von claude ist und der Watchdog sie beenden kann.
  local prompt=$1 p; shift
  [[ -r ~/.config/deepseek/env ]] || { echo "~/.config/deepseek/env fehlt" >&2; exit 1; }
  set -a; . ~/.config/deepseek/env; set +a
  local -a gesperrt=() effort=() modus
  for p in "${DS_NUR_LESEN[@]}"; do gesperrt+=("Edit($p/**)" "Write($p/**)"); done
  [[ -z ${DS_EFFORT:-} ]] || effort=(--effort "$DS_EFFORT")
  if [[ $MODUS == plan || $MODUS == lage ]]; then
    local rolle=$PLAN_ROLLE
    [[ $MODUS == lage ]] && rolle=$LAGE_ROLLE
    modus=(--append-system-prompt "$rolle" --max-turns "$PLAN_ZUEGE_MAX"
           --setting-sources project,local
           --tools Read,Glob,Grep --allowedTools Read Glob Grep
           --disallowedTools WebFetch WebSearch)
  else
    # Pruef-Hook nach jedem Edit; nur Projekt-Einstellungen laden, nicht die des
    # Nutzers (dessen Hooks, z. B. Prompt-Sperren, gelten fuer den Arbeiter nicht).
    # Merk-Hook nach Lese-Schritten: verlangt die Aufgabenliste (Staffelstab).
    local settings="$ARBEIT/$name.settings.json"
    jq -n --arg c "$REPO/ds/arbeiter-pruef.sh" \
          --arg m "$(printf '%q %q' "$REPO/ds/arbeiter-merker.sh" "$KONTEXT_MAX")" '{hooks:{PostToolUse:[
      {matcher:"Edit|Write|MultiEdit", hooks:[{type:"command", command:$c, timeout:60}]},
      {matcher:"Read|Grep|Glob", hooks:[{type:"command", command:$m, timeout:20}]}]}}' > "$settings"
    modus=(--append-system-prompt "$ROLLE" --permission-mode acceptEdits
           --setting-sources project,local --settings "$settings"
           --max-turns "$ZUEGE_MAX"
           --tools Read,Edit,Write,Glob,Grep,Bash,TodoWrite
           --allowedTools Read Edit Write Glob Grep TodoWrite
             "${DS_ERLAUBT[@]}"
             'Bash(git status:*)' 'Bash(git diff:*)' 'Bash(git log:*)'
             'Bash(ls:*)' 'Bash(grep:*)'
           --disallowedTools "${gesperrt[@]}"
             'Bash(git commit:*)' 'Bash(git push:*)' 'Bash(git checkout:*)'
             'Bash(git reset:*)' 'Bash(git switch:*)' WebFetch WebSearch)
  fi
  cd "$WT"
  exec env -u ANTHROPIC_API_KEY \
      ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic \
      ANTHROPIC_AUTH_TOKEN="$DEEPSEEK_API_KEY" \
      ANTHROPIC_MODEL="$MODEL" \
      ANTHROPIC_DEFAULT_OPUS_MODEL="$MODEL" \
      ANTHROPIC_DEFAULT_SONNET_MODEL="$MODEL" \
      ANTHROPIC_DEFAULT_HAIKU_MODEL="$MODEL" \
      CLAUDE_CODE_SUBAGENT_MODEL="$MODEL" \
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
      DEEPSEEK_API_KEY= \
    claude -p --model "$MODEL" --output-format stream-json --verbose \
      --include-partial-messages "${modus[@]}" "${effort[@]}" \
      "$@" < "$prompt"
}

probe() {  # Erreichbarkeit: kommt binnen PROBE_MAX s ein echtes Token?
  set -a; . ~/.config/deepseek/env; set +a
  # { ...; true; }: grep -q endet beim ersten Treffer, der SIGPIPE von curl
  # darf unter pipefail nicht als Fehler zaehlen.
  { curl -s -N -m "$PROBE_MAX" https://api.deepseek.com/anthropic/v1/messages \
    -H "x-api-key: $DEEPSEEK_API_KEY" -H 'anthropic-version: 2023-06-01' \
    -H 'content-type: application/json' \
    -d '{"model":"'"$MODEL"'","max_tokens":16,"stream":true,"messages":[{"role":"user","content":"ok"}]}' \
    2>/dev/null; true; } | grep -q -m1 'content_block_delta' && return 0
  echo "ds-worker: ABBRUCH -- $MODEL liefert binnen $PROBE_MAX s kein Token" \
    "(https://status.deepseek.com; spaeter erneut)" >&2
  return 3
}

laufe() {  # $1 Prompt-Datei, $2 Ergebnis-JSON, weitere Argumente an claude
  # Streamt jedes Token ins Protokoll. Frist fuer Stille: laeuft gerade ein
  # Werkzeug (letztes Nicht-Stream-Ereignis ist ein tool_use), STILL_MAX,
  # sonst wartet claude auf die API: API_STILL_MAX. Bei Abbruch wird claude
  # beendet und ein Ersatz-Ergebnis geschrieben (abbruch_watchdog, Exit 3).
  local prompt=$1 out=$2; shift 2
  local log="$ARBEIT/$name.stream.jsonl" grund= etappe= still frist ctx letzt start=$SECONDS
  # Ein frueherer Lauf (Nacharbeit, Etappe) bleibt fuer die Auswertung erhalten.
  [[ -s $log ]] && cat "$log" >> "$ARBEIT/$name.stream-frueher.jsonl"
  : > "$log"
  starte_claude "$prompt" "$@" > "$log" &
  local pid=$!
  trap 'kill -TERM '"$pid"' 2>/dev/null || true' EXIT INT TERM
  while kill -0 "$pid" 2>/dev/null; do
    sleep "${DS_TAKT:-5}"   # Watchdog-Takt (Tests: DS_TAKT=1)
    still=$(( $(date +%s) - $(stat -c %Y "$log") ))
    frist=$API_STILL_MAX
    letzt=$(letztes_ereignis "$log")
    [[ $letzt == *'"tool_use"'* ]] && frist=$STILL_MAX
    if (( still > frist )); then grund="keine Ausgabe seit $still s (Frist $frist s; $MODEL haengt? https://status.deepseek.com)"; break; fi
    if (( SECONDS - start > LAUF_MAX )); then grund="Laufzeit ueber $LAUF_MAX s"; break; fi
    # Etappenwechsel: Kontext zu gross und zwischen zwei Zuegen (letztes
    # Ereignis = Werkzeug-Ergebnis oder "status requesting"). Edits sind dann
    # abgeschlossen; verloren geht hoechstens die begonnene Antwort.
    ctx=$(kontext "$log")
    if (( ctx > KONTEXT_MAX )) &&
       [[ $letzt == '{"type":"user"'* || $letzt == '{"type":"system","subtype":"status"'* ]]; then
      etappe=1; grund="Kontext $ctx Token ueber $KONTEXT_MAX"; break
    fi
  done
  if [[ -n $grund ]]; then
    kill -TERM "$pid" 2>/dev/null || true; sleep 3; kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
  trap - EXIT INT TERM
  # Token-Deltas brauchte nur der Watchdog als Lebenszeichen; im Protokoll
  # bleiben die ganzen Nachrichten (sonst leicht 30 MB, fast nur Deltas).
  # message_delta bleibt: nur dort steht die Ausgabe-Tokenzahl je API-Aufruf
  # (die assistant-Nachrichten im Stream tragen output_tokens 0).
  awk '!/"subtype":"thinking_tokens"/ && (!/"type":"stream_event"/ || /"type":"message_delta"/)' \
    "$log" > "$log.neu" || true
  mv "$log.neu" "$log"
  grep '"type":"result"' "$log" | tail -n1 > "$out" || true
  # Selbst beendet (Watchdog/Etappe): claude schreibt beim Beenden oft noch ein
  # eigenes error_during_execution -- der Grund des Skripts hat Vorrang.
  if [[ -n $grund || ! -s $out ]]; then
    grund=${grund:-"claude endete ohne Ergebnis"}
    # Ersatz-Ergebnis; Token aus den Nachrichten des Protokolls (je message.id
    # die vollstaendigste), damit tokens.py auch abgebrochene Laeufe zaehlt.
    # Ausgabe aus den message_delta-Ereignissen (bis 2026-10-05 stand hier
    # bei jeder Etappe 0).
    local sid; sid=$(grep -m1 -o '"session_id":"[^"]*"' "$log" | cut -d'"' -f4 || true)
    local typ=abbruch_watchdog text="ABBRUCH (Watchdog): $grund. Spaeter erneut mit nacharbeit."
    [[ -n $etappe ]] && { typ=etappe; text="ETAPPE: $grund; frische Sitzung macht weiter."; }
    jq -s --arg typ "$typ" --arg text "$text" --arg sid "$sid" --argjson ms $(( (SECONDS - start) * 1000 )) '
      [.[] | select(.type == "stream_event" and .event.type == "message_delta")
       | .event.usage.output_tokens // 0] as $delta
      | [.[] | select(.type == "assistant" and .message.usage)] | group_by(.message.id)
      | map(max_by(.message.usage.output_tokens) | .message.usage) as $u
      | {type:"result", subtype:$typ, is_error:($typ != "etappe"), session_id:$sid,
         num_turns:($u|length), duration_ms:$ms, permission_denials:[],
         usage:{input_tokens:([$u[].input_tokens]|add // 0),
                cache_read_input_tokens:([$u[].cache_read_input_tokens // 0]|add // 0),
                cache_creation_input_tokens:([$u[].cache_creation_input_tokens // 0]|add // 0),
                output_tokens:([([$u[].output_tokens]|add // 0), ($delta|add // 0)]|max)},
         result:$text}' "$log" > "$out"
    [[ -n $etappe ]] && return 4
    echo "ds-worker: ABBRUCH -- $grund" >&2
    return 3
  fi
}

# tac | grep -m1: grep endet beim ersten Treffer, tac bekommt SIGPIPE -- unter
# pipefail waere die ganze Pipeline "falsch". Darum Ausgabe statt Exit-Status.
letztes_ereignis() {  # $1 Stream-Protokoll -> letzte Zeile ausser Token-Deltas
  { tac "$1" | grep -m1 -v -e '"type":"stream_event"' -e '"subtype":"thinking_tokens"'; } 2>/dev/null || true
}

kontext() {  # $1 Stream-Protokoll -> Kontextgroesse der letzten Antwort (Token)
  local n
  n=$({ tac "$1" | grep -m1 '^{"type":"assistant"'; } 2>/dev/null | jq '.message.usage | .input_tokens
      + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)' 2>/dev/null) || true
  echo "${n:-0}"
}

staffelstab() {  # $1 Grund-Prompt, $2 Etappe -> stdout: Prompt fuer die frische Sitzung
  local log="$ARBEIT/$name.stream.jsonl"
  cat <<EOF
# Fortsetzung, Etappe $2: frische Sitzung, gleiche Arbeit

Du setzt eine begonnene Arbeit im selben Worktree fort. Die vorige Sitzung
endete, weil ihr Kontext zu gross wurde; der Auftrag unten gilt unveraendert
und vollstaendig. Erkunde nicht neu: lies geaenderte Dateien gezielt
(\`git diff -- <datei>\`) und mach bei der Aufgabenliste weiter.

## Stand: geaenderte Dateien
\`\`\`
$(zeige_diff --stat | tail -n 40)
\`\`\`

## Deine letzte Aufgabenliste
$(jq -rs '[.[] | select(.type == "assistant") | .message.content[]?
  | select(.type == "tool_use" and .name == "TodoWrite") | .input.todos] | last // []
  | map("- [\(.status)] \(.content)") | .[]' "$log" 2>/dev/null || true)

## Deine letzten Notizen
$(jq -rs '[.[] | select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text]
  | .[-2:] | .[]' "$log" 2>/dev/null | tail -c 2000 || true)

---

EOF
  cat "$1"
}

diff_stand() { zeige_diff --binary | sha1sum | cut -c1-40; }

zu_gross() {  # $1 Ergebnis-JSON, $2 Grund -> Ergebnis umschreiben, Exit 6
  local text="ZU GROSS: $2 Die Arbeit passt nicht in eine Sitzung von $KONTEXT_MAX Token.
Opus: Auftrag in Pakete teilen oder Plan-Modus (Befunde statt ganzer Dateien).
Was fertig ist, liegt im Worktree (ds/ds-worker.sh diff $name --stat)."
  jq --arg t "$text" '.subtype = "zu_gross" | .is_error = true | .result = $t' "$1" > "$1.neu"
  mv "$1.neu" "$1"
  echo "ds-worker: ZU GROSS -- $2" >&2
  return 6
}

laufe_etappen() {  # wie laufe, aber bei Etappenwechsel (Exit 4) frisch weiter
  # Fortschritt = der Worktree-Diff hat sich in der Etappe geaendert. Ohne
  # Fortschritt einmal Vorerkundung (Lagekarte), danach Exit 6 statt einer
  # weiteren Etappe, die dasselbe noch einmal liest.
  local prompt=$1 out=$2 rc etappe=1 vorher; shift 2
  while :; do
    vorher=$(diff_stand)
    rc=0; laufe "$prompt" "$out" "$@" || rc=$?
    (( rc == 4 )) || return $rc
    if (( etappe >= ETAPPEN_MAX )); then
      zu_gross "$out" "Etappengrenze $ETAPPEN_MAX erreicht, Arbeit nicht fertig."; return
    fi
    jq -c . "$out" >> "$ARBEIT/$name.laeufe.jsonl"   # Zwischenlauf fuer die Kostenmessung
    if [[ $(diff_stand) == "$vorher" ]]; then
      if [[ -e $ARBEIT/$name.lage.json || $VORERKUNDUNG == aus ]]; then   # schon versucht
        zu_gross "$out" "Etappe $etappe endete ohne neue Aenderung im Worktree$(
          [[ -s $ARBEIT/$name.lage.md ]] && echo ' trotz Lagekarte' ||
          { [[ -e $ARBEIT/$name.lage.json ]] && echo ', Vorerkundung gescheitert'; })."; return
      fi
      echo "ds-worker: Etappe $etappe ohne Aenderung im Worktree -- Vorerkundung (Lagekarte) vor der naechsten" >&2
      vorerkunden "$GRUND_PROMPT" ||
        { zu_gross "$out" "Etappe $etappe ohne Aenderung, Vorerkundung gescheitert."; return; }
    fi
    etappe=$(( etappe + 1 ))
    echo "ds-worker: Etappe $etappe -- Kontext ueber $KONTEXT_MAX, frische Sitzung" >&2
    staffelstab "$GRUND_PROMPT" "$etappe" > "$ARBEIT/$name.etappe.md"
    prompt="$ARBEIT/$name.etappe.md"
    set --   # kein --resume mehr
  done
}

lesebudget() {  # $1 Prompt-Datei -> Tabelle; stdout letzte Zeile: Token gesamt
  DS_REPO=$REPO python3 "$REPO/ds/plan.py" budget "$1"
}

lage_weg() {  # Reste einer frueheren Vorerkundung gleichen Namens (neuer Lauf)
  rm -f "$ARBEIT/$name".{lage.md,lage.md.unbrauchbar,lage.json,start.md,budget.md}
}

vorerkunden() {  # $1 Grund-Prompt -> Lagekarte $name.lage.md; GRUND_PROMPT = Auftrag + Lagekarte
  # Nur-Lese-Sitzung im Worktree mit der Erkunder-Rolle, ohne Etappen (die
  # Lagekarte ist ihre letzte Antwort). Scheitert sie, baut der Arbeiter ohne.
  local grund=$1 json="$ARBEIT/$name.lage.json" lage="$ARBEIT/$name.lage.md"
  local start="$ARBEIT/$name.start.md" rc=0 alt_modus=$MODUS alt_max=$KONTEXT_MAX fehlt
  MODUS=lage; KONTEXT_MAX=999999999
  rc=0; laufe "$grund" "$json" || rc=$?
  MODUS=$alt_modus; KONTEXT_MAX=$alt_max
  jq -c . "$json" >> "$ARBEIT/$name.laeufe.jsonl"   # zaehlt in tokens.py mit
  jq -r '"--- Vorerkundung: \(.subtype), \(.num_turns) Zuege, \(.duration_ms/1000|floor) s"' "$json" >&2
  (( rc == 0 )) || { echo "ds-worker: Vorerkundung abgebrochen (Exit $rc), weiter ohne Lagekarte" >&2; return 1; }
  jq -r '.result // ""' "$json" > "$lage"
  fehlt=$(for a in Fundstellen Reihenfolge; do grep -q "^## $a" "$lage" || echo "$a"; done)
  if [[ -n $fehlt ]]; then
    echo "ds-worker: Lagekarte ohne Abschnitt $(echo $fehlt) -- weiter ohne (siehe $lage)" >&2
    mv "$lage" "$lage.unbrauchbar"; return 1
  fi
  echo "ds-worker: Lagekarte $(wc -l < "$lage") Zeilen: ds/arbeit/$name.lage.md" >&2
  { cat "$grund"
    printf '\n## Lagekarte (Vorerkundung, nur Fakten; der Auftrag oben gilt vor)\n\n'
    sed 's/^## /### /' "$lage"
    printf '\nBaue jetzt. Lege zuerst die Reihenfolge der Lagekarte als Aufgabenliste\n'
    printf '(TodoWrite) an. Lies nur die Fundstellen (Read mit offset/limit), keine ganzen\n'
    printf 'Dateien; Schnittstellen stehen oben. Erkunde nur nach, was dort fehlt.\n'
  } > "$start"
  GRUND_PROMPT=$start
  echo "$start" > "$ARBEIT/$name.grund"
}

auswerten() {  # $1 JSON-Ergebnis des Laufs
  local json=$1
  jq -c . "$json" >> "$ARBEIT/$name.laeufe.jsonl"   # jeder Lauf, fuer die Kostenmessung
  jq -r '.result // "(kein Ergebnistext)"' "$json" > "$ARBEIT/$name.bericht.md"
  local etappen; etappen=$(grep -c '"subtype":"etappe"' "$ARBEIT/$name.laeufe.jsonl" || true)
  (( etappen == 0 )) || echo "--- Etappen (frische Sitzung bei grossem Kontext): $etappen" >> "$ARBEIT/$name.bericht.md"
  { [[ -s $ARBEIT/$name.budget.md ]] && tail -n1 "$ARBEIT/$name.budget.md"
    if [[ -s $ARBEIT/$name.lage.md ]]; then
      echo "--- Vorerkundung: ja, Lagekarte $(wc -l < "$ARBEIT/$name.lage.md") Zeilen (ds/arbeit/$name.lage.md; Luecken dort fuer Opus)"
    elif [[ -e $ARBEIT/$name.lage.json ]]; then
      echo "--- Vorerkundung: gescheitert, gebaut ohne Lagekarte"
    fi; } >> "$ARBEIT/$name.bericht.md"
  cat "$ARBEIT/$name.bericht.md"
  echo
  jq -r '"--- Lauf: \(.subtype), \(.num_turns) Zuege, \(.duration_ms/1000|floor) s, " +
         "Token ein \(.usage.input_tokens + .usage.cache_read_input_tokens) " +
         "(davon Cache \(.usage.cache_read_input_tokens)), aus \(.usage.output_tokens)"' "$json"
  [[ $(jq '.permission_denials|length' "$json") == 0 ]] ||
    jq -r '"--- verweigert: " + ([.permission_denials[]|.tool_name + " " + (.tool_input.command // .tool_input.file_path // "")]|join(" | "))' "$json"
  tokens
  echo "--- Diff:"; zeige_diff --stat
}

tokens() {  # Tabelle Opus / Bauleiter / DeepSeek mit Kosten und Ersparnis
  DS_MODEL=$MODEL python3 "$REPO/ds/tokens.py" "$name" || true
}

pruefen() {  # $1 Verzeichnis; Befehle: ```-Block unter "## Abnahme" im Auftrag
  local dir=$1 auftrag="$ARBEIT/$name.auftrag.md" rot=0 aus befehl m
  [[ -r $auftrag ]] || { echo "$auftrag fehlt" >&2; return 1; }
  local -a befehle muster=()
  mapfile -t befehle < <(awk '/^## Abnahme/{a=1;next} /^## /{a=0}
    a && /^```/{b=!b;next} a && b && NF && !/^#/' "$auftrag")
  (( ${#befehle[@]} )) || { echo 'keine Abnahmebefehle (```-Block unter ## Abnahme)' >&2; return 1; }
  for m in "${DS_FEHLERMUSTER[@]}"; do muster+=(-e "$m"); done
  vor_pruefen "$dir"
  echo "--- Abnahme in $dir:"
  for befehl in "${befehle[@]}"; do
    if aus=$(cd "$dir" && bash -c "$befehl" 2>&1) &&
       { (( ${#muster[@]} == 0 )) || ! grep -q "${muster[@]}" <<<"$aus"; }; then
      echo "gruen  $befehl"
    else
      rot=1; echo "ROT    $befehl"; tail -n 8 <<<"$aus" | sed 's/^/       /'
    fi
  done
  return $rot
}

zeige_diff() {
  git -C "$WT" add -A -N .   # neue Dateien im Diff sichtbar machen
  git -C "$WT" --no-pager diff HEAD "$@"   # HEAD = Basis, nur Arbeit des Arbeiters
}

uebernehmen_einzeln() {  # je geaenderter Datei: anwenden, kopieren, 3way; Bericht; Exit 1 = Rest offen
  local st f p fehler erg rest=0 n=0
  echo "--- Ganzer Patch passt nicht sauber; Datei fuer Datei:"
  git -C "$WT" add -A -N .
  while IFS=$'\t' read -r st f; do
    n=$(( n + 1 ))
    p=$(mktemp); fehler=$(mktemp)
    git -C "$WT" --no-pager diff --binary --no-renames HEAD -- "$f" > "$p"
    if git -C "$REPO" apply --reverse --check "$p" 2>/dev/null; then
      erg="schon da     (Haupt-Checkout hat den Stand bereits)"
    elif git -C "$REPO" apply --check "$p" 2>/dev/null; then
      git -C "$REPO" apply "$p"; erg="ok"
    elif [[ $st == A && -e $REPO/$f ]]; then
      if cmp -s "$WT/$f" "$REPO/$f"; then erg="schon da     (neue Datei gleich vorhanden)"
      else erg="KONFLIKT     neue Datei existiert im Haupt-Checkout mit anderem Inhalt"; rest=1; fi
    elif [[ $st == A ]]; then
      mkdir -p "$(dirname "$REPO/$f")"; cp "$WT/$f" "$REPO/$f"; erg="kopiert      (neue Datei)"
    else
      # --3way braucht Index = Arbeitsstand der Datei (Lehre runden-log):
      # nur diese eine Datei stagen, damit fremde Aenderungen erhalten bleiben.
      git -C "$REPO" ls-files --error-unmatch -- "$f" >/dev/null 2>&1 && git -C "$REPO" add -- "$f"
      if git -C "$REPO" apply --3way "$p" 2> "$fehler"; then
        erg="3way         zusammengefuehrt (Datei ist jetzt gestagt)"
      elif [[ -n $(git -C "$REPO" diff --name-only --diff-filter=U -- "$f") ]]; then
        erg="KONFLIKT     Marker in der Datei (<<<<<<<), beide Seiten pruefen; gestagt"; rest=1
      else
        erg="FEHLT        $(grep -m1 -v '^$' "$fehler")"; rest=1
      fi
    fi
    printf '    %-1s %-48s %s\n' "$st" "$f" "$erg"
    rm -f "$p" "$fehler"
  done < <(git -C "$WT" diff --name-status --no-renames HEAD)
  echo "--- $n Dateien; $( (( rest )) && echo 'Rest offen (KONFLIKT/FEHLT oben)' || echo 'alle uebernommen')"
  return $rest
}

auftrag_pruefen() {  # $1 Auftrag, $2 Vorlage: Platzhalterzeilen offen? Abnahme da?
  # Opus schreibt den Auftrag direkt nach der Vorlage: unausgefuellte
  # Platzhalterzeilen oder fehlende Abnahme vor dem Lauf abfangen.
  local rest
  [[ -r $1 ]] || { echo "$1 fehlt" >&2; exit 1; }
  rest=$(grep -F -x -f <(grep '<' "$2" | grep -v -e '^<!--' -e '^ ') "$1" || true)
  [[ -z $rest ]] || { printf 'Auftrag hat unausgefuellte Vorlagenzeilen:\n%s\n' "$rest" >&2; exit 1; }
  awk '/^## Abnahme/{a=1;next} /^## /{a=0} a && /^```/{b=!b;next} a && b && NF && !/^#/{n++} END{exit !n}' "$1" ||
    { echo 'Auftrag ohne Abnahmebefehle (```sh-Block unter ## Abnahme)' >&2; exit 1; }
}

worktree_anlegen() {
  [[ ! -e $WT ]] || { echo "Worktree $WT existiert schon (nacharbeit/verwerfen?)" >&2; exit 1; }
  rm -f "$ARBEIT/$name.rc"
  probe || { echo 3 > "$ARBEIT/$name.rc"; exit 3; }   # vor dem Worktree: haengt das Modell, bleibt nichts liegen
  mkdir -p "$WT_BASIS"
  git -C "$REPO" worktree add -q -b "$ZWEIG" "$WT" HEAD
  # Basis ist der aktuelle Arbeitsstand, nicht nur HEAD: nicht committete
  # Aenderungen des Haupt-Checkouts wandern als Basis-Commit mit (nur im
  # ds-Zweig). uebernehmen bringt danach nur zurueck, was der Arbeiter tat.
  if ! git -C "$REPO" diff --quiet HEAD; then
    git -C "$REPO" diff --binary HEAD | git -C "$WT" apply --index -
    git -C "$WT" commit -q --no-verify -m "ds-Basis: Arbeitsstand von $(git -C "$REPO" rev-parse --short HEAD)"
  fi
  # Neue, noch nicht versionierte Dateien gehoeren zum Arbeitsstand: sie kommen
  # in den Basis-Commit, damit der Arbeiter sie liest.
  local neu f p
  neu=$(git -C "$REPO" ls-files --others --exclude-standard | grep -v '^ds/' || true)
  if [[ -n $neu ]]; then
    while IFS= read -r f; do
      mkdir -p "$WT/$(dirname "$f")"; cp "$REPO/$f" "$WT/$f"
    done <<<"$neu"
    git -C "$WT" add -- $neu
    git -C "$WT" commit -q --no-verify -m "ds-Basis: neue Dateien des Arbeitsstands"
  fi
  # Nicht versionierte Teile, die Bauen/Tests brauchen (ds/projekt.sh).
  for p in "${DS_KOPIEREN[@]}"; do
    if [[ -e $REPO/$p ]]; then
      mkdir -p "$WT/$(dirname "$p")"; cp -r --reflink=auto "$REPO/$p" "$WT/$p"
    fi
  done
}

worktree_weg() {
  git -C "$REPO" worktree remove --force "$WT"
  git -C "$REPO" branch -D "$ZWEIG" >/dev/null
}

plan_py() { DS_WT_BASIS=$WT_BASIS python3 "$REPO/ds/plan.py" "$@"; }

# Grund-Prompt eines Laufs: Basis fuer den Staffelstab bei Etappenwechsel.
GRUND_PROMPT=

case $cmd in
start)
  auftrag="$ARBEIT/$name.auftrag.md"
  auftrag_pruefen "$auftrag" "$REPO/ds/auftrag-vorlage.md"
  lage_weg
  budget_ausgabe=$(lesebudget "$auftrag" 2>&1) || budget_ausgabe=$'Lesebudget nicht ermittelbar\n0'
  lese=$(tail -n1 <<<"$budget_ausgabe"); [[ $lese =~ ^[0-9]+$ ]] || lese=0
  sed '$d' <<<"$budget_ausgabe" > "$ARBEIT/$name.budget.md"
  worktree_anlegen
  echo "$auftrag" > "$ARBEIT/$name.grund"
  GRUND_PROMPT=$auftrag
  echo "--- Lesebudget (Kern): ~$(( lese / 1000 ))k Token (Vorerkundung ab $(( LESEBUDGET / 1000 ))k," \
       "Etappe ab $(( KONTEXT_MAX / 1000 ))k; Tabelle ds/arbeit/$name.budget.md)" >> "$ARBEIT/$name.budget.md"
  if [[ $VORERKUNDUNG == immer ]] || { [[ $VORERKUNDUNG == auto ]] && (( lese > LESEBUDGET )); }; then
    echo "ds-worker: Lesebudget (Kern) ~$(( lese / 1000 ))k Token ueber $(( LESEBUDGET / 1000 ))k -- Vorerkundung" >&2
    vorerkunden "$auftrag" || true
  fi
  rc=0; laufe_etappen "$GRUND_PROMPT" "$ARBEIT/$name.json" || rc=$?
  auswerten "$ARBEIT/$name.json"
  echo $rc > "$ARBEIT/$name.rc"
  exit $rc
  ;;
plan)
  # Planphase: nur lesen, im eigenen Worktree (Arbeitsstand, keine Sitzung im
  # Haupt-Projekt). Der Plan ist die letzte Antwort; der Worktree wird danach
  # verworfen -- bauen beginnt frisch auf dem dann aktuellen Arbeitsstand.
  auftrag="$ARBEIT/$name.auftrag.md"
  auftrag_pruefen "$auftrag" "$REPO/ds/plan-vorlage.md"
  rm -f "$ARBEIT/$name.plan.md" "$ARBEIT/$name.freigabe.md"
  worktree_anlegen
  MODUS=plan
  KONTEXT_MAX=999999999   # kein Etappenwechsel: der Plan ist die letzte Antwort einer Sitzung
  rc=0; laufe "$auftrag" "$ARBEIT/$name.json" || rc=$?
  jq -c . "$ARBEIT/$name.json" >> "$ARBEIT/$name.laeufe.jsonl"
  worktree_weg
  if (( rc == 0 )); then
    jq -r '.result // ""' "$ARBEIT/$name.json" > "$ARBEIT/$name.plan.md"
    { echo "Plan: ds/arbeit/$name.plan.md (Opus liest ihn direkt)"
      plan_py pruefen "$name" || rc=5
      jq -r '"--- Planlauf: \(.subtype), \(.num_turns) Zuege, \(.duration_ms/1000|floor) s"' "$ARBEIT/$name.json"
    } > "$ARBEIT/$name.bericht.md"
  else
    jq -r '.result // "(kein Ergebnis)"' "$ARBEIT/$name.json" > "$ARBEIT/$name.bericht.md"
  fi
  cat "$ARBEIT/$name.bericht.md"
  echo $rc > "$ARBEIT/$name.rc"
  exit $rc
  ;;
form) plan_py pruefen "$name" ;;
budget)
  # Fuer Opus beim Schreiben des Auftrags: was liest der Arbeiter? Ueber der
  # Grenze erkundet start zuerst vor (Lagekarte); besser: Auftrag teilen.
  auftrag="$ARBEIT/$name.auftrag.md"
  [[ -r $auftrag ]] || { echo "$auftrag fehlt" >&2; exit 1; }
  aus=$(lesebudget "$auftrag"); lese=$(tail -n1 <<<"$aus")
  sed '$d' <<<"$aus"
  if (( lese > KONTEXT_MAX )); then
    echo "=> Kern ueber der Etappengrenze ($(( KONTEXT_MAX / 1000 ))k): teilen oder Plan-Modus; start erkundet sonst vor."
  elif (( lese > LESEBUDGET )); then
    echo "=> Kern ueber $(( LESEBUDGET / 1000 ))k: start erkundet zuerst vor (Lagekarte, ~5-10 min). Grosse Kern-Dateien mit datei:zeile eingrenzen oder teilen."
  else
    echo "=> passt: Kern unter $(( LESEBUDGET / 1000 ))k, keine Vorerkundung."
  fi
  ;;
bauen)
  # Bauphase: frische Sitzung (kein --resume: die Planungssitzung ist schon
  # gross und wuerde sofort zusammengefasst). Prompt = Auftrag + Plan + Freigabe.
  auftrag="$ARBEIT/$name.auftrag.md" plan="$ARBEIT/$name.plan.md" frei="$ARBEIT/$name.freigabe.md"
  [[ -s $plan ]] || { echo "$plan fehlt -- erst plan" >&2; exit 1; }
  [[ -s $frei ]] || { echo "$frei fehlt -- Opus gibt den Plan frei" >&2; exit 1; }
  n=$(plan_py pakete "$name")
  if (( n > 1 )) && ! grep -qiE '^[-* ]*Schnitt: *ein Paket' "$frei"; then
    echo "Plan hat $n Pakete: ds-worker.sh teilen $name (oder 'Schnitt: ein Paket' in der Freigabe)" >&2; exit 1
  fi
  bau="$ARBEIT/$name.bau.md"
  { cat "$auftrag"
    printf '\n## Plan (von dir in der Planphase erstellt, von Opus freigegeben)\n\n'
    sed 's/^## /### /' "$plan"
    printf '\n## Freigabe (Opus) -- gilt vor dem Plan\n\n'
    sed 's/^## /### /' "$frei"
    printf '\nBaue jetzt. Starte bei den Befunden des Plans; erkunde nur nach, was dort fehlt.\n'
  } > "$bau"
  lage_weg
  worktree_anlegen
  echo "$bau" > "$ARBEIT/$name.grund"
  GRUND_PROMPT=$bau
  rc=0; laufe_etappen "$bau" "$ARBEIT/$name.json" || rc=$?
  auswerten "$ARBEIT/$name.json"
  echo $rc > "$ARBEIT/$name.rc"
  exit $rc
  ;;
teilen)
  [[ -s $ARBEIT/$name.freigabe.md ]] || { echo "$name.freigabe.md fehlt -- Opus gibt den Plan frei" >&2; exit 1; }
  plan_py teilen "$name"
  ;;
nacharbeit)
  notiz="$ARBEIT/$name.nacharbeit.md"
  [[ -r $notiz && -d $WT ]] || { echo "$notiz oder Worktree fehlt" >&2; exit 1; }
  sid=$(jq -r .session_id "$ARBEIT/$name.json")
  [[ -n $sid ]] || { echo "keine session_id in $name.json" >&2; exit 1; }
  rm -f "$ARBEIT/$name.rc"
  probe || { echo 3 > "$ARBEIT/$name.rc"; exit 3; }
  # Grund-Prompt fuer den Staffelstab: urspruenglicher Auftrag + diese Notiz.
  voll="$ARBEIT/$name.nacharbeit-voll.md"
  { cat "$(cat "$ARBEIT/$name.grund" 2>/dev/null || echo "$ARBEIT/$name.auftrag.md")"
    printf '\n## Nacharbeit (aktuell, gilt vor dem Auftrag)\n\n'; cat "$notiz"; } > "$voll"
  GRUND_PROMPT=$voll
  # Kleine Sitzung fortsetzen (sie kennt den Code); grosse oder per Etappe
  # beendete Sitzung frisch mit Staffelstab (sonst sofort Compaction).
  rc=0
  if [[ $(jq -r .subtype "$ARBEIT/$name.json") == etappe ]] ||
     (( $(kontext "$ARBEIT/$name.stream.jsonl") > KONTEXT_MAX / 2 )); then
    staffelstab "$voll" 1 > "$ARBEIT/$name.etappe.md"
    laufe_etappen "$ARBEIT/$name.etappe.md" "$ARBEIT/$name.json.neu" || rc=$?
  else
    laufe_etappen "$notiz" "$ARBEIT/$name.json.neu" --resume "$sid" || rc=$?
  fi
  mv "$ARBEIT/$name.json.neu" "$ARBEIT/$name.json"
  auswerten "$ARBEIT/$name.json"
  echo $rc > "$ARBEIT/$name.rc"
  exit $rc
  ;;
diff) zeige_diff "${@:3}" ;;
tokens) tokens ;;
uebernehmen)
  # Erst als Ganzes ohne Index (Staging des Nutzers bleibt unberuehrt). Passt
  # das nicht (paralleler Auftrag, dirty Baum, neue Datei schon da), Datei fuer
  # Datei mit Bericht -- vorher machte Opus das jedes Mal von Hand
  # (fuchs-client, runden-log, p4-vertrag, menue-ring).
  [[ -d $WT ]] || { echo "Worktree $WT fehlt" >&2; exit 1; }
  rest=0
  patch=$(mktemp); zeige_diff --binary > "$patch"
  if git -C "$REPO" apply --check "$patch" 2>/dev/null; then
    git -C "$REPO" apply "$patch"; rm -f "$patch"
    echo "--- uebernommen (ganzer Patch sauber):"; zeige_diff --stat | tail -n 40
    worktree_weg
  else
    rm -f "$patch"
    uebernehmen_einzeln || rest=$?
    if (( rest )); then
      echo "--- Worktree bleibt fuer den Rest: $WT"
      echo "    Rest von Hand: ds/ds-worker.sh diff $name -- <datei>; Konfliktmarker loesen;"
      echo "    danach ds/ds-worker.sh verwerfen $name"
    else
      worktree_weg
    fi
  fi
  echo "nicht committet: git -C $REPO status"
  pruefen "$REPO" || echo "ds-worker: Abnahme im Haupt-Checkout ROT" >&2
  exit $(( rest ? 1 : 0 ))
  ;;
pruefen)
  if [[ ${3:-} == --haupt ]]; then pruefen "$REPO"; else pruefen "$WT"; fi
  ;;
warte)
  # Fuer den Bauleiter: start/plan/bauen/nacharbeit laufen im Hintergrund; ein
  # Aufruf wartet bis zum Ende (oder WARTE_MAX s), zeigt dann Bericht + Umfang.
  ende=$(( SECONDS + WARTE_MAX ))
  while pgrep -f "ds-worker.sh (start|plan|bauen|nacharbeit) $name\$" >/dev/null; do
    (( SECONDS < ende )) || { echo "laeuft noch -- warte erneut aufrufen"; exit 0; }
    sleep 5
  done
  echo "--- Lauf beendet, Exit $(cat "$ARBEIT/$name.rc" 2>/dev/null || echo '?')"
  cat "$ARBEIT/$name.bericht.md" 2>/dev/null || echo "(kein Bericht)"
  [[ -d $WT ]] && { echo "--- Diff:"; zeige_diff --stat; }
  ;;
verwerfen)
  worktree_weg
  echo "verworfen"
  ;;
*) sed -n 6,20p "$0"; exit 2 ;;
esac
