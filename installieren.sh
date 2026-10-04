#!/usr/bin/env bash
# Bauleiter in ein Projekt installieren oder dort aktualisieren.
#
#   ./installieren.sh <projekt>            # erstmalig oder Update
#   ./installieren.sh <projekt> --pruefen  # nur zeigen, was sich aendern wuerde
#
# Werkzeug-Dateien (ds-worker.sh, Hooks, tokens.py, Agent) kommen IMMER aus
# diesem Modul und werden ueberschrieben -- Verbesserungen hier machen, dann
# installieren. Projekteigene Dateien (projekt.sh, auftrag-/plan-vorlage.md) werden
# nur angelegt, wenn sie fehlen; LEHREN.md nur bei der Erstinstallation
# (ein Projekt darf seine Lehren woanders fuehren, z. B. im Gedaechtnis).
set -euo pipefail

MODUL=$(cd "$(dirname "$0")" && pwd)
V="$MODUL/vorlage"
ziel=${1:-}; modus=${2:-}
[[ -n $ziel ]] || { sed -n 4,10p "$0"; exit 2; }
ziel=$(git -C "$ziel" rev-parse --show-toplevel 2>/dev/null) ||
  { echo "$1 ist kein git-Repository (der Bauleiter braucht git-Worktrees)" >&2; exit 1; }

WERKZEUG=(ds/ds-worker.sh ds/arbeiter-pruef.sh ds/bauleiter-sperre.sh ds/tokens.py
          ds/plan.py .claude/agents/ds-bauleiter.md)
PROJEKT=(ds/projekt.sh ds/auftrag-vorlage.md ds/plan-vorlage.md)
[[ -e $ziel/ds/ds-worker.sh ]] || PROJEKT+=(ds/LEHREN.md)   # Erstinstallation

if [[ $modus == --pruefen ]]; then
  for f in "${WERKZEUG[@]}"; do
    if [[ ! -e $ziel/$f ]]; then echo "neu        $f"
    elif ! cmp -s "$V/$f" "$ziel/$f"; then echo "geaendert  $f"; diff -u "$ziel/$f" "$V/$f" | sed -n '3,$p' | head -n 40
    fi
  done
  for f in "${PROJEKT[@]}"; do [[ -e $ziel/$f ]] || echo "neu        $f (Projektdatei)"; done
  exit 0
fi

mkdir -p "$ziel/ds/arbeit" "$ziel/.claude/agents"
for f in "${WERKZEUG[@]}"; do
  cmp -s "$V/$f" "$ziel/$f" 2>/dev/null && continue
  cp "$V/$f" "$ziel/$f"; echo "installiert  $f"
done
for f in "${PROJEKT[@]}"; do
  if [[ -e $ziel/$f ]]; then echo "behalten     $f (Projektdatei)"
  else cp "$V/$f" "$ziel/$f"; echo "angelegt     $f -> anpassen!"; fi
done
chmod +x "$ziel"/ds/*.sh

gi="$ziel/.gitignore"
grep -qx 'ds/arbeit/' "$gi" 2>/dev/null || { echo 'ds/arbeit/' >> "$gi"; echo "ergaenzt     .gitignore: ds/arbeit/"; }

bash "$ziel/ds/bauleiter-sperre.sh" --test >/dev/null && echo "Sperre: Selbsttest gruen"
fehlt=()
for c in git jq curl python3 pgrep claude; do command -v "$c" >/dev/null || fehlt+=("$c"); done
(( ${#fehlt[@]} == 0 )) || echo "WARNUNG: fehlende Werkzeuge: ${fehlt[*]}"
[[ -r ~/.config/deepseek/env ]] || echo "WARNUNG: ~/.config/deepseek/env fehlt (DEEPSEEK_API_KEY=...)"
grep -qs 'ds-bauleiter' "$ziel/CLAUDE.md" ||
  echo "TODO: Abschnitt aus $MODUL/CLAUDE-baustein.md in $ziel/CLAUDE.md uebernehmen"
echo "Fertig. Claude Code im Projekt neu starten, damit der Agent geladen wird."
