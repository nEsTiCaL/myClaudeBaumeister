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

WERKZEUG=(ds/ds-worker.sh ds/arbeiter-pruef.sh ds/arbeiter-merker.sh ds/karte-hinweis.sh
          ds/bauleiter-sperre.sh ds/tokens.py ds/plan.py .claude/agents/ds-bauleiter.md)
PROJEKT=(ds/projekt.sh ds/auftrag-vorlage.md ds/plan-vorlage.md)
[[ -e $ziel/ds/ds-worker.sh ]] || PROJEKT+=(ds/LEHREN.md)   # Erstinstallation

# ds/karte (Struktur fuer Opus, Go-Binary): mit go + C-Compiler hier bauen, sonst
# das fertige Binary aus dem Paket (paket.sh) nehmen. Fehlt beides: ohne karte.
KARTE=$MODUL/karte/karte
KARTE_RECHT='Bash(ds/karte:*)'   # ohne Freigabe fragt jeder Aufruf nach -- Opus weicht dann auf Read aus
if command -v go >/dev/null && command -v cc >/dev/null; then
  (cd "$MODUL/karte" && go build -o karte .) || echo "WARNUNG: karte nicht gebaut (go build, siehe oben)" >&2
fi

if [[ $modus == --pruefen ]]; then
  for f in "${WERKZEUG[@]}"; do
    if [[ ! -e $ziel/$f ]]; then echo "neu        $f"
    elif ! cmp -s "$V/$f" "$ziel/$f"; then echo "geaendert  $f"
      { diff -u "$ziel/$f" "$V/$f" || true; } | sed -n '3,$p' | head -n 40 || true   # diff: Exit 1 bei Unterschied
    fi
  done
  for f in "${PROJEKT[@]}"; do [[ -e $ziel/$f ]] || echo "neu        $f (Projektdatei)"; done
  if [[ -x $KARTE ]]; then
    [[ -e $ziel/ds/karte ]] || echo "neu        ds/karte"
    [[ -e $ziel/ds/karte ]] && ! cmp -s "$KARTE" "$ziel/ds/karte" && echo "geaendert  ds/karte (Binary)"
    jq -e --arg r "$KARTE_RECHT" '.permissions.allow // [] | index($r)' "$ziel/.claude/settings.json" \
      >/dev/null 2>&1 || echo "neu        .claude/settings.json: $KARTE_RECHT"
    jq -e '[.hooks.PostToolUse[]?.hooks[]? | select((.command // "") | contains("karte-hinweis.sh"))] | length > 0' \
      "$ziel/.claude/settings.json" >/dev/null 2>&1 || echo "neu        .claude/settings.json: Hook karte-hinweis"
  fi
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
if [[ -x $KARTE ]]; then
  cmp -s "$KARTE" "$ziel/ds/karte" 2>/dev/null || { cp "$KARTE" "$ziel/ds/karte"; echo "installiert  ds/karte"; }
  st="$ziel/.claude/settings.json"
  if ! jq -e --arg r "$KARTE_RECHT" '.permissions.allow // [] | index($r)' "$st" >/dev/null 2>&1; then
    [[ -e $st ]] || echo '{}' > "$st"
    tmp=$(mktemp) && jq --arg r "$KARTE_RECHT" '.permissions.allow = ((.permissions.allow // []) + [$r])' "$st" > "$tmp" &&
      mv "$tmp" "$st" && echo "ergaenzt     .claude/settings.json: $KARTE_RECHT"
  fi
  # Opus bekommt nach jedem Bash/Grep/Read die Funktionsgrenzen der neu
  # beruehrten Code-Dateien und Verwendungen der gesuchten Bezeichner.
  if ! jq -e '[.hooks.PostToolUse[]?.hooks[]? | select((.command // "") | contains("karte-hinweis.sh"))] | length > 0' "$st" >/dev/null 2>&1; then
    [[ -e $st ]] || echo '{}' > "$st"
    tmp=$(mktemp) && jq '.hooks.PostToolUse = ((.hooks.PostToolUse // []) + [{"matcher":"Bash|Grep|Read","hooks":[{"type":"command","command":"\"$CLAUDE_PROJECT_DIR\"/ds/karte-hinweis.sh","timeout":10}]}])' "$st" > "$tmp" &&
      mv "$tmp" "$st" && echo "ergaenzt     .claude/settings.json: Hook karte-hinweis"
  fi
else
  echo "WARNUNG: ds/karte fehlt (go + cc oder Paket mit Binary noetig) -- Opus liest dann selbst"
fi

gi="$ziel/.gitignore"
grep -qx 'ds/arbeit/' "$gi" 2>/dev/null || { echo 'ds/arbeit/' >> "$gi"; echo "ergaenzt     .gitignore: ds/arbeit/"; }

bash "$ziel/ds/bauleiter-sperre.sh" --test >/dev/null && echo "Sperre: Selbsttest gruen"
bash "$ziel/ds/arbeiter-merker.sh" --test >/dev/null && echo "Merk-Hook: Selbsttest gruen"
bash "$ziel/ds/karte-hinweis.sh" --test >/dev/null && echo "Karte-Hinweis: Selbsttest gruen"
fehlt=()
for c in git jq curl python3 pgrep claude; do command -v "$c" >/dev/null || fehlt+=("$c"); done
(( ${#fehlt[@]} == 0 )) || echo "WARNUNG: fehlende Werkzeuge: ${fehlt[*]}"
[[ -r ~/.config/deepseek/env ]] || echo "WARNUNG: ~/.config/deepseek/env fehlt (DEEPSEEK_API_KEY=...)"
grep -qs 'ds-bauleiter' "$ziel/CLAUDE.md" ||
  echo "TODO: Abschnitt aus $MODUL/CLAUDE-baustein.md in $ziel/CLAUDE.md uebernehmen"
# Grenzen und Verwendungen liefert der Hook karte-hinweis.sh von selbst; die
# Befehle (symbol, gliederung) kennt Opus nur aus CLAUDE.md -- die liest es vor
# der Erkundung, eine Delegations-Doku erst danach (2026-10-05: 4 Laeufe, 0 Aufrufe).
[[ -x $ziel/ds/karte ]] && ! grep -qs 'ds/karte' "$ziel/CLAUDE.md" &&
  echo "Hinweis (optional): Abschnitt \"Struktur ohne Lesen: ds/karte\" aus $MODUL/CLAUDE-baustein.md in $ziel/CLAUDE.md"
echo "Fertig. Claude Code im Projekt neu starten, damit der Agent geladen wird."
