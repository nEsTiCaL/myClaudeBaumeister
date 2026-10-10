#!/usr/bin/env bash
# PostToolUse-Hook des Arbeiters nach Read/Grep/Glob (von ds/ds-worker.sh
# per --settings gesetzt): verlangt die Aufgabenliste .ds/aufgaben.md im
# Worktree, die bei einem Etappenwechsel der Staffelstab ist.
# Bis 2026-10-10 war das TodoWrite. Claude Code 2.1.29x bietet headless kein
# TodoWrite mehr (statt dessen TaskCreate/TaskUpdate), das Werkzeug fiel still
# aus der Liste. Seither ist die Liste eine Datei: haengt an keinem
# Werkzeugnamen und liegt nach einem Abbruch noch auf der Platte. Als
# Aktualisierung zaehlt Write/Edit auf diese Datei (TodoWrite/Task* weiter mit).
# Anlass 2026-10-05 ui-zusammenbau: Etappe 1 las 21 Zuege lang ganze Dateien,
# ohne TodoWrite und ohne Notiz; Etappe 2 bekam einen leeren Staffelstab und
# las alles noch einmal. Die Regel im Rollen-Prompt allein reichte nicht.
#
# Erinnert (additionalContext), blockiert nie:
#   A) noch keine Aufgabenliste und >= DS_MERK_LESEN (12) Lese-Schritte,
#      danach jeden 4. Lese-Schritt erneut;
#   B) Kontext ueber 60 % der Etappengrenze ($1) und seit dem Ueberschreiten
#      keine Aufgabenliste aktualisiert: beim 1., 5., 9. ... Lese-Schritt danach.
#
# Eingabe: Hook-JSON auf stdin (transcript_path). Immer Exit 0.
# Selbsttest: ds/arbeiter-merker.sh --test
set -uo pipefail

grenze=${1:-110000}

auswerten() {  # $1 Transkript (jsonl), $2 Etappengrenze -> Hinweistext oder nichts
  python3 - "$1" "$2" "${DS_MERK_LESEN:-12}" <<'PY'
import json, sys
pfad, grenze, ab = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
schwelle = int(grenze * 0.6)
LESEN = {"Read", "Grep", "Glob"}
LISTE_WERKZEUG = {"TodoWrite", "TaskCreate", "TaskUpdate"}   # aeltere/andere Claude-Code-Versionen
SCHREIBEN = {"Write", "Edit", "MultiEdit"}

def ist_liste(b):
    if b.get("name") in LISTE_WERKZEUG:
        return True
    pfad = str((b.get("input") or {}).get("file_path", "")).replace(chr(92), "/")
    return b.get("name") in SCHREIBEN and pfad.endswith(".ds/aufgaben.md")

ctx = 0
todo_ctx = None            # Kontext bei der letzten Aktualisierung der Liste
lesen_seit_todo = 0        # Lese-Schritte seit der letzten Aktualisierung (oder Start)
lesen_ueber = 0            # Lese-Schritte, seit der Kontext ueber der Schwelle ist
gesehen = set()
for zeile in open(pfad, encoding="utf-8", errors="replace"):
    try:
        o = json.loads(zeile)
    except ValueError:
        continue
    if o.get("type") != "assistant":
        continue
    m = o.get("message") or {}
    u = m.get("usage") or {}
    c = (u.get("input_tokens") or 0) + (u.get("cache_read_input_tokens") or 0) \
        + (u.get("cache_creation_input_tokens") or 0)
    if c:
        ctx = c
    for b in m.get("content") or []:
        if b.get("type") != "tool_use" or b.get("id") in gesehen:
            continue
        gesehen.add(b.get("id"))
        if ist_liste(b):
            todo_ctx, lesen_seit_todo = ctx, 0
            if ctx >= schwelle:
                lesen_ueber = 0
        elif b.get("name") in LESEN:
            lesen_seit_todo += 1
            if ctx >= schwelle and (todo_ctx is None or todo_ctx < schwelle):
                lesen_ueber += 1
liste = ("Lege die Aufgabenliste .ds/aufgaben.md an (Write): je Punkt '- [ ] Teilschritt -- "
         "datei:zeile' mit den Fundstellen, die du schon gefunden hast. Sie ist dein Staffelstab: "
         "wird der Kontext zu gross, macht eine frische Sitzung NUR mit dieser Liste und "
         "dem Diff weiter -- alles Gelesene ohne Liste ist dann verloren.")
if todo_ctx is None and lesen_seit_todo >= ab and (lesen_seit_todo - ab) % 4 == 0:
    print(f"Merk-Hook: {lesen_seit_todo} Lese-Schritte ohne Aufgabenliste (Kontext ~{ctx // 1000}k "
          f"von {grenze // 1000}k). " + liste + " Danach bauen statt weiterlesen.")
elif lesen_ueber and (lesen_ueber - 1) % 4 == 0:
    print(f"Merk-Hook: Kontext ~{ctx // 1000}k von {grenze // 1000}k -- bald frische Sitzung. "
          "Aktualisiere jetzt die Aufgabenliste .ds/aufgaben.md (Edit): Stand je Punkt und die Fundstellen "
          "(datei:zeile) der offenen Punkte. Lies danach nur noch, was der naechste Edit braucht.")
PY
}

if [[ ${1:-} == --test ]]; then
  t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
  msg() {  # $1 ctx, $2 Werkzeug, $3 file_path (optional, JSON-escaped) -> eine Transkriptzeile
    printf '{"type":"assistant","message":{"usage":{"input_tokens":%d},"content":[{"type":"tool_use","id":"t%s","name":"%s","input":{"file_path":"%s"}}]}}\n' \
      "$1" "$RANDOM$RANDOM" "$2" "${3:-}"
  }
  fall() {  # $1 erwartet (leer|A|B), $2 Transkript
    local aus; aus=$(auswerten "$2" 100000)
    case $1 in
      leer) [[ -z $aus ]] ;;
      A) [[ $aus == *"ohne Aufgabenliste"* ]] ;;
      B) [[ $aus == *"bald frische Sitzung"* ]] ;;
    esac && echo "ok   $1 ($3)" || { echo "FEHL erwartet $1 ($3): $aus"; exit 1; }
  }
  : > "$t/a"; for i in $(seq 11); do msg 20000 Read >> "$t/a"; done
  fall leer "$t/a" "11 Lese-Schritte"
  msg 20000 Grep >> "$t/a"; fall A "$t/a" "12. Lese-Schritt ohne Liste"
  msg 20000 Read >> "$t/a"; fall leer "$t/a" "13.: nicht jedes Mal"
  for i in 1 2 3; do msg 20000 Read >> "$t/a"; done; fall A "$t/a" "16.: wieder"
  msg 20000 Write .ds/aufgaben.md >> "$t/a"; msg 30000 Read >> "$t/a"; fall leer "$t/a" "Liste da, Kontext klein"
  msg 61000 Read >> "$t/a"; fall B "$t/a" "ueber 60 %, Liste von vorher"
  msg 62000 Read >> "$t/a"; fall leer "$t/a" "2. Schritt ueber 60 %"
  msg 63000 Edit .ds/aufgaben.md >> "$t/a"; msg 64000 Read >> "$t/a"; fall leer "$t/a" "Liste ueber 60 % aktualisiert"
  : > "$t/c"; for i in $(seq 11); do msg 20000 Read >> "$t/c"; done
  msg 20000 Edit src/main.go >> "$t/c"; msg 20000 Read >> "$t/c"; fall A "$t/c" "Edit an anderer Datei ist keine Liste"
  : > "$t/e"; msg 70000 Write 'D:\\wt\\.ds\\aufgaben.md' >> "$t/e"; msg 70000 Read >> "$t/e"
  fall leer "$t/e" "Liste per Windows-Pfad ueber 60 % angelegt (ohne Erkennung: B)"
  : > "$t/d"; msg 20000 TaskCreate >> "$t/d"; for i in $(seq 12); do msg 20000 Read >> "$t/d"; done
  fall leer "$t/d" "TaskCreate zaehlt weiter als Liste"
  : > "$t/b"; for i in $(seq 5); do msg 70000 Read >> "$t/b"; done
  fall B "$t/b" "ohne Liste ueber 60 %, 5. Schritt (vor A)"
  msg 70000 Edit >> "$t/b"; msg 70000 Read >> "$t/b"; fall leer "$t/b" "Edit zaehlt nicht als Lesen"
  echo "arbeiter-merker: Selbsttest gruen"
  exit 0
fi

ein=$(cat)
tp=$(jq -r '.transcript_path // empty' <<<"$ein")
[[ -n $tp && -r $tp ]] || exit 0
text=$(auswerten "$tp" "$grenze" 2>/dev/null)
[[ -n $text ]] || exit 0
jq -n --arg t "$text" '{hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext:$t}}'
exit 0
