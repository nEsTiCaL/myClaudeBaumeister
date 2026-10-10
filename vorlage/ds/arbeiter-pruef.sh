#!/usr/bin/env bash
# PostToolUse-Hook des Arbeiters (von ds/ds-worker.sh per --settings
# gesetzt): prueft nach jedem Edit/Write die Datei mit nach_edit() aus
# ds/projekt.sh und haengt Fehler als additionalContext an das Tool-Ergebnis.
# Anlass 2026-10-04: tempo-v7 baute 98 Zuege ohne Pruefung, danach Rot-Welle
# (8 von 20 Testlaeufen rot). Fehler im selben Zug sparen Test-Fix-Runden.
#
# Eingabe: Hook-JSON auf stdin. Immer Exit 0 (meldet nur, blockiert nie).
# Selbsttest: ds/arbeiter-pruef.sh --test <datei>   (cwd = Repo/Worktree)
set -uo pipefail

nach_edit() { :; }
. "$(dirname "$0")/projekt.sh"

if [[ ${1:-} == --test ]]; then
  nach_edit "$2"; exit 0
fi

ein=$(cat)
datei=$(jq -r '.tool_input.file_path // empty' <<<"$ein")
cwd=$(jq -r '.cwd // empty' <<<"$ein")
[[ -n $datei && -n $cwd && -f $datei ]] || exit 0
cd "$cwd" || exit 0
rel=$(realpath --relative-to=. "$datei")
[[ $rel != ../* ]] || exit 0
[[ $rel != .ds/* ]] || exit 0   # Aufgabenliste des Arbeiters, kein Projektcode

fehler=$(timeout 30 bash -c "$(declare -f nach_edit); nach_edit \"\$1\"" _ "$rel" 2>&1)
[[ -n ${fehler//[[:space:]]/} ]] || exit 0
jq -n --arg t "Pruef-Hook $rel meldet:
$fehler
Beheben, bevor du weitermachst -- ausser der Fehler stammt erkennbar von einem
noch offenen Teil desselben Teilschritts (z. B. Aufrufer noch nicht angepasst)." \
  '{hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext:$t}}'
exit 0
