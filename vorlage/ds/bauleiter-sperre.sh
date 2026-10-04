#!/usr/bin/env bash
# PreToolUse-Hook des Bauleiters (.claude/agents/ds-bauleiter.md, frontmatter).
# Sperrt technisch, was der Prompt verbietet -- Anlass 2026-10-02: Haiku-
# Bauleiter uebernahmen selbst, committeten und setzten Aenderungen anderer
# Auftraege im Haupt-Checkout zurueck (Lehren-Tabelle des Projekts).
#
# Eingabe: Hook-JSON auf stdin. Exit 2 = blockiert, stderr geht an den Agenten.
# Selbsttest: ds/bauleiter-sperre.sh --test
set -euo pipefail

pruefe() {
  python3 -c '
import json, re, sys
o = json.load(sys.stdin)
tool = o.get("tool_name", "")
inp = o.get("tool_input") or {}
if tool == "Bash":
    c = inp.get("command", "")
    verboten = [
        (r"ds-worker\.sh\s+(uebernehmen|verwerfen)\b", "uebernehmen/verwerfen macht nur Opus"),
        (r"ds-worker\.sh\s+teilen\b", "teilen entscheidet Opus nach der Freigabe"),
        (r"\bgit\b(\s+-C\s+\S+)?\s+(commit|add|reset|checkout|restore|stash|apply|rm|clean|push|merge|rebase|cherry-pick|worktree|branch)\b",
         "Git-Schreibbefehle macht nur Opus; der Haupt-Checkout enthaelt fremde Aenderungen anderer Auftraege"),
        (r"(^|[;&|]\s*)(rm|mv)\s", "Dateien loeschen/verschieben ist nicht deine Aufgabe"),
    ]
    # start/plan/bauen/nacharbeit laufen 5-15 min: ein kurzer Timeout (Haiku
    # setzte 60 s) killt DeepSeek mitten im Lauf (p3-local-player,
    # p3-sitzordnung, p3-feld-anzeige 2026-10-02). Hintergrund ohne Timeout = 30 min, gut.
    if re.search(r"ds-worker\.sh\s+(start|plan|bauen|nacharbeit)\b", c):
        if not inp.get("run_in_background"):
            sys.exit("GESPERRT (Bauleiter): start/plan/bauen/nacharbeit nur mit run_in_background: true, danach warte.")
        t = inp.get("timeout")
        if t is not None and int(t) < 1800000:
            sys.exit("GESPERRT (Bauleiter): start/plan/bauen/nacharbeit ohne timeout aufrufen (Vorgabe 30 min); %s ms bricht DeepSeek ab." % t)
    for muster, grund in verboten:
        if re.search(muster, c):
            sys.exit("GESPERRT (Bauleiter): " + grund + ". Melde es stattdessen im Bericht.")
elif tool in ("Write", "Edit"):
    # Nur Nacharbeitsnotizen. Auftrag und Freigabe schreibt Opus, den Plan
    # DeepSeek: beim Umschreiben gingen Entscheidungen verloren (fuchs-jeder:
    # Debuff-Ausschluss, 2026-10-04).
    p = inp.get("file_path", "")
    if not re.search(r"(^|/)ds/arbeit/[a-z0-9-]+\.nacharbeit\.md$", p):
        sys.exit("GESPERRT (Bauleiter): schreiben nur ds/arbeit/<name>.nacharbeit.md; den Auftrag schreibt Opus, nicht " + p)
'
}

if [[ ${1:-} == --test ]]; then
  fall() { # erwartet(0/2) json
    local rc=0; printf '%s' "$2" | pruefe 2>/dev/null || rc=2
    [[ $rc == "$1" ]] && echo "ok   $2" || { echo "FEHL $2 (rc $rc, erwartet $1)"; exit 1; }
  }
  fall 0 '{"tool_name":"Bash","tool_input":{"command":"ds/ds-worker.sh pruefen x"}}'
  fall 0 '{"tool_name":"Bash","tool_input":{"command":"ds/ds-worker.sh warte x"}}'
  fall 0 '{"tool_name":"Bash","tool_input":{"command":"git status --short"}}'
  fall 0 '{"tool_name":"Bash","tool_input":{"command":"git -C ../x diff --stat"}}'
  fall 0 '{"tool_name":"Bash","tool_input":{"command":"ds/ds-worker.sh start x","run_in_background":true}}'
  fall 0 '{"tool_name":"Bash","tool_input":{"command":"ds/ds-worker.sh nacharbeit x","run_in_background":true,"timeout":3600000}}'
  fall 2 '{"tool_name":"Bash","tool_input":{"command":"ds/ds-worker.sh start x","run_in_background":true,"timeout":60000}}'
  fall 2 '{"tool_name":"Bash","tool_input":{"command":"ds/ds-worker.sh start x"}}'
  fall 2 '{"tool_name":"Bash","tool_input":{"command":"ds/ds-worker.sh uebernehmen x"}}'
  fall 0 '{"tool_name":"Bash","tool_input":{"command":"ds/ds-worker.sh plan x","run_in_background":true}}'
  fall 0 '{"tool_name":"Bash","tool_input":{"command":"ds/ds-worker.sh bauen x","run_in_background":true}}'
  fall 2 '{"tool_name":"Bash","tool_input":{"command":"ds/ds-worker.sh bauen x"}}'
  fall 0 '{"tool_name":"Bash","tool_input":{"command":"ds/ds-worker.sh form x"}}'
  fall 2 '{"tool_name":"Bash","tool_input":{"command":"ds/ds-worker.sh teilen x"}}'
  fall 2 '{"tool_name":"Bash","tool_input":{"command":"cd /r && git commit -m x"}}'
  fall 2 '{"tool_name":"Bash","tool_input":{"command":"git -C /r checkout -- a.gd"}}'
  fall 2 '{"tool_name":"Bash","tool_input":{"command":"git restore client/main.gd"}}'
  fall 2 '{"tool_name":"Bash","tool_input":{"command":"ls; rm -rf ds"}}'
  fall 0 '{"tool_name":"Write","tool_input":{"file_path":"/r/ds/arbeit/x.nacharbeit.md"}}'
  fall 2 '{"tool_name":"Write","tool_input":{"file_path":"/r/ds/arbeit/x.auftrag.md"}}'
  fall 2 '{"tool_name":"Edit","tool_input":{"file_path":"ds/arbeit/x.auftrag.md"}}'
  fall 2 '{"tool_name":"Write","tool_input":{"file_path":"ds/arbeit/x.freigabe.md"}}'
  fall 2 '{"tool_name":"Edit","tool_input":{"file_path":"ds/arbeit/x.plan.md"}}'
  fall 2 '{"tool_name":"Write","tool_input":{"file_path":"/r/client/main.gd"}}'
  echo "bauleiter-sperre: Selbsttest gruen"
  exit 0
fi

msg=$(pruefe 2>&1) || { echo "$msg" >&2; exit 2; }
exit 0
