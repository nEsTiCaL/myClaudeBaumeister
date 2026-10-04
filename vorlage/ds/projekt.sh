# Projektanpassung fuer ds/ds-worker.sh -- die einzige Datei, die du anpassen musst.
# Wird von ds-worker.sh eingelesen (source). Beispiele unten fuer ein Node-Projekt;
# Wird auch vom Pruef-Hook ds/arbeiter-pruef.sh gelesen (nach_edit).

# Bash-Befehle, die der Arbeiter ausfuehren darf (Claude-Code-Rechtesyntax).
# Nur Praefixe fuer Bauen/Testen/Lint. Verkettete Befehle (&&, ;) verweigert
# Claude Code ohnehin; der Arbeiter weicht dann auf Einzelbefehle aus.
# Immer erlaubt (fest im Skript): git status/diff/log, ls, grep.
DS_ERLAUBT=(
  'Bash(npm test:*)'
  'Bash(npm run lint:*)'
  'Bash(npx tsc:*)'
)

# Verzeichnisse, die der Arbeiter nur LESEN darf (Projektgedaechtnis, Doku).
DS_NUR_LESEN=(memory docs)

# Nicht versionierte Pfade, die Bauen/Tests im Worktree brauchen; werden beim
# start mit cp --reflink=auto hineinkopiert (fehlende werden uebersprungen).
DS_KOPIEREN=(node_modules .env.test)

# Ausgabe-Muster, die einen Abnahmebefehl trotz Exit 0 ROT machen
# (Godot z. B.: 'SCRIPT ERROR' 'Parse Error'). Leer = nur Exit-Code zaehlt.
DS_FEHLERMUSTER=()

# Satz fuer die Arbeiter-Rolle: wo stehen die Bau-/Testbefehle?
DS_HINWEIS_PRUEFEN='Pruefe deine Arbeit mit den Befehlen unter "## Abnahme" im Auftrag.'

# Wird vor jeder Abnahme mit dem Zielverzeichnis als $1 aufgerufen, z. B. um
# generierte Dateien zu kopieren. Standard: nichts tun.
vor_pruefen() { :; }

# Nach jedem Edit/Write des Arbeiters (Hook ds/arbeiter-pruef.sh), cwd = Worktree.
# $1 = Datei relativ zum Worktree. Ausgabe = Fehler (leer = in Ordnung); wird
# dem Arbeiter im selben Zug gemeldet. Schnell halten (< 5 s): Syntax/Typen.
# Beispiele: Go: go vet "./$(dirname "$1")/"   Python: python3 -m py_compile "$1"
nach_edit() {
  case $1 in
    *.ts|*.tsx) npx tsc --noEmit -p . 2>&1 | grep -F "$1" | head -n 12 || true ;;
  esac
}
