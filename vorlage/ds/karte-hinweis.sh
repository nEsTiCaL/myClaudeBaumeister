#!/usr/bin/env bash
# PostToolUse-Hook fuer Opus (Bash/Grep/Read): liefert im selben Zug die
# Funktionsgrenzen der dabei NEU beruehrten Code-Dateien (ds/karte index) und zu
# gesuchten Bezeichnern Definition + Verwendungen je umschliessender Funktion
# (ds/karte verwendung). Opus soll dadurch ohne geratene sed-Bereiche und
# Definitions-greps auskommen (weniger Folgezuege).
#
# Eingabe: Hook-JSON auf stdin. Immer Exit 0 (meldet nur, blockiert nie).
# Abschalten: DS_KARTE_HINWEIS=aus (Umgebung oder ds/projekt.sh).
# Selbsttest: ds/karte-hinweis.sh --test
set -uo pipefail

if [[ ${1:-} == --test ]]; then
  S=$(realpath -- "$0")
  t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
  R="$t/repo"; K="$t/karte"; M="$t/aufrufe.log"
  mkdir -p "$R/server"
  git init -q "$R"
  for i in $(seq 12); do printf 'func f%s() {}\n' "$i" > "$R/server/f$i.go"; done
  printf 'func a() {}\n' > "$R/server/a.go"
  printf 'func b() {}\n' > "$R/server/b.go"
  printf 'func c() {}\n' > "$R/server/c.go"

  cat > "$K" <<'MOCK'
#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
try:
    with open(os.environ.get("MOCK_LOG", "/dev/null"), "a") as f:
        f.write(" ".join(args) + "\n")
except OSError:
    pass
code = [a for a in args if a.endswith((".go", ".gd", ".py"))]
if args[:1] == ["index"]:
    if os.environ.get("MOCK_INDEX_RIESIG"):
        sys.stdout.write("x" * 20000); sys.exit(0)
    for i, d in enumerate(code):
        print(f"{d}: f{i} {i * 10 + 1}-{i * 10 + 10}")
    if os.environ.get("MOCK_INDEX_VERSTECKT") and code[1:]:
        print("... nicht gezeigt: " + " ".join(code[1:]))
elif args[:1] == ["verwendung"]:
    if os.environ.get("MOCK_VERWENDUNG_FEHLT"):
        sys.exit(2)
    if os.environ.get("MOCK_VERWENDUNG_RIESIG"):
        sys.stdout.write("y" * 20000); sys.exit(0)
    print(f"Definition {args[-1]} server/a.go 1-10")
    print("Aufrufe: server/b.go 5")
MOCK
  chmod +x "$K"

  fehler=0
  ok() { echo "ok   $1"; }
  nein() { echo "FEHLER $1: ${2:-}"; fehler=1; }
  h() {  # $1 Eingabe-JSON; Rest env-Zuweisungen -> $aus, $rc
    local ein=$1; shift
    rc=0
    aus=$(printf '%s' "$ein" | env -i PATH="$PATH" HOME="$HOME" \
          CLAUDE_PROJECT_DIR="$R" DS_KARTE="$K" MOCK_LOG="$M" "$@" \
          bash "$S" 2>/dev/null) || rc=$?
  }
  jread() {  # $1 sid, $2 datei
    jq -nc --arg s "$1" --arg c "$R" --arg f "$2" \
      '{session_id:$s,cwd:$c,tool_name:"Read",tool_input:{file_path:$f},tool_response:{}}'
  }
  jbash() {  # $1 sid, $2 befehl, $3 stdout
    jq -nc --arg s "$1" --arg c "$R" --arg cmd "$2" --arg o "$3" \
      '{session_id:$s,cwd:$c,tool_name:"Bash",tool_input:{command:$cmd},tool_response:{stdout:$o,stderr:""}}'
  }
  text() { jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$1"; }

  # 1./2. gleiche Datei zweimal -> 2. Mal nichts; nach mtime-Aenderung wieder
  touch -m -d '2001-01-01T00:00:00Z' "$R/server/a.go"
  ein=$(jread s1 "$R/server/a.go")
  h "$ein"
  { [[ $rc == 0 && $(text "$aus") == *"server/a.go:"* ]]; } && ok "erster Lesezugriff liefert Grenzen" \
    || nein "erster Lesezugriff" "$aus"
  h "$ein"
  { [[ $rc == 0 && -z $(text "$aus") ]]; } && ok "gleiche Datei zweimal, 2. Mal nichts" \
    || nein "gleiche Datei zweimal" "$aus"
  touch -m -d '2002-01-01T00:00:00Z' "$R/server/a.go"
  h "$ein"
  { [[ $(text "$aus") == *"server/a.go:"* ]]; } && ok "nach mtime-Aenderung erneut geliefert" \
    || nein "mtime" "$aus"

  # 3. grep mit 12 Treffer-Dateien -> genau 8, nach Trefferzahl
  out=""
  for i in $(seq 12); do for _ in $(seq "$i"); do out+="server/f$i.go:1:x
"; done; done
  : > "$M"
  h "$(jbash s2 'grep -rn "func x" server/' "$out")"
  iz=$(grep -c '^index ' "$M" 2>/dev/null || true)
  args=$(grep '^index ' "$M" | head -n1 | tr ' ' '\n' | grep -c '\.go$' || true)
  erst=$(grep '^index ' "$M" | head -n1 | tr ' ' '\n' | grep '\.go$' | head -n1 || true)
  { [[ $iz == 1 && $args == 8 && $erst == server/f12.go ]]; } \
    && ok "12 Treffer -> 8 index-Dateien, haeufigste zuerst" || nein "8-Dateien-Grenze" "args=$args erst=$erst"

  # 4. Bezeichner aus grep-Muster
  : > "$M"
  h "$(jbash s3 'grep -rn "func lookAllowed" server/' 'server/b.go:3:func lookAllowed() {}')"
  { [[ $(text "$aus") == *"Definition lookAllowed"* ]]; } && ok "grep -rn \"func lookAllowed\" -> Bezeichner" \
    || nein "Bezeichner lookAllowed" "$aus"
  : > "$M"
  h "$(jbash s4 'grep -n "x.*y"' 'server/b.go:1:xay')"
  { [[ $(text "$aus") == *"server/b.go:"* && $(grep -c '^verwendung ' "$M") == 0 ]]; } \
    && ok "Regex-Muster -> kein Bezeichner" || nein "kein Bezeichner x.*y" "$aus"
  : > "$M"
  h "$(jbash s5 'grep -E "a|b_c"' 'server/b.go:1:b_c')"
  { grep -q '^verwendung --max-zeichen 2500 b_c$' "$M" && [[ $(grep -c '^verwendung ' "$M") == 1 ]]; } \
    && ok "Alternative a|b_c -> nur b_c" || nein "Alternative b_c" "$(cat "$M")"

  # 5. Gedaechtnis/Doku -> nichts
  h "$(jbash s6 'grep -rn "func x" memory/' 'memory/x.go:1:func x')"
  { [[ -z $(text "$aus") ]]; } && ok "grep auf memory/ -> nichts" || nein "memory/" "$aus"
  h "$(jbash s7 'grep -rn "func x" docs/a.md' 'docs/a.md:1:func x')"
  { [[ -z $(text "$aus") ]]; } && ok "grep auf *.md -> nichts" || nein "*.md" "$aus"

  # 6. Attrappe verwendung Exit 2 -> nur index; 20 000 Zeichen -> <= 9000
  ein=$(jbash s8 'grep -rn "func lookAllowed" server/' 'server/b.go:3:func lookAllowed() {}')
  h "$ein" MOCK_VERWENDUNG_FEHLT=1
  { [[ $(text "$aus") == *"server/b.go:"* && $(text "$aus") != *"Definition"* ]]; } \
    && ok "verwendung Exit 2 -> nur index" || nein "Exit 2" "$aus"
  h "$ein" MOCK_VERWENDUNG_RIESIG=1
  gel=$(printf '%s' "$aus" | jq -r '.hookSpecificOutput.additionalContext | length' 2>/dev/null)
  { [[ -n $gel && $gel -le 9000 ]] && printf '%s' "$aus" | jq -e . >/dev/null 2>&1; } \
    && ok "verwendung 20 000 Zeichen -> <= 9000 und gueltiges JSON" || nein "Kappung" "$gel"
  h "$(jread s14 "$R/server/c.go")" MOCK_INDEX_RIESIG=1
  gel=$(printf '%s' "$aus" | jq -r '.hookSpecificOutput.additionalContext | length' 2>/dev/null)
  { [[ -n $gel && $gel -le 9000 ]] && printf '%s' "$aus" | jq -e . >/dev/null 2>&1; } \
    && ok "index 20 000 Zeichen -> <= 9000 und gueltiges JSON" || nein "Kappung index" "$gel"

  # 7. abschalten / Karte fehlt / kaputtes stdin / ausserhalb der Wurzel
  h "$(jread s9 "$R/server/b.go")" DS_KARTE_HINWEIS=aus
  { [[ -z $(text "$aus") ]]; } && ok "DS_KARTE_HINWEIS=aus -> nichts" || nein "abgeschaltet" "$aus"
  h "$(jread s10 "$R/server/b.go")" DS_KARTE="$t/gibtsnicht"
  { [[ -z $(text "$aus") ]]; } && ok "Karte fehlt -> nichts" || nein "Karte fehlt" "$aus"
  rc=0; aus=$(printf 'kein json' | env -i PATH="$PATH" HOME="$HOME" \
        CLAUDE_PROJECT_DIR="$R" DS_KARTE="$K" bash "$S" 2>/dev/null) || rc=$?
  { [[ $rc == 0 && -z $aus ]]; } && ok "kaputtes stdin -> nichts, Exit 0" || nein "kaputtes stdin" "rc=$rc"
  h "$(jread s11 /etc/ausserhalb.go)"
  { [[ -z $(text "$aus") ]]; } && ok "Pfad ausserhalb der Wurzel -> ignoriert" || nein "ausserhalb" "$aus"
  mkdir -p "$R/ds"
  printf 'DS_KARTE_HINWEIS=aus\n' > "$R/ds/projekt.sh"
  h "$(jread s15 "$R/server/b.go")"
  { [[ -z $(text "$aus") ]]; } && ok "projekt.sh aus -> nichts" || nein "projekt.sh aus" "$aus"
  h "$(jread s16 "$R/server/b.go")" DS_KARTE_HINWEIS=an
  { [[ $(text "$aus") == *"server/b.go:"* ]]; } && ok "Umgebung an schlaegt projekt.sh aus" \
    || nein "Vorrang der Umgebung" "$aus"
  printf 'DS_KARTE_HINWEIS=an\n' > "$R/ds/projekt.sh"

  # 8. sed -n liest gezielt: direkt gelesene Datei kommt in den index
  : > "$M"
  h "$(jbash s12 'sed -n 1,5p server/c.go' 'func c() {}')"
  { grep '^index ' "$M" | grep -q 'server/c.go'; } && ok "sed -n -> Datei im index" \
    || nein "sed -n" "$(cat "$M")"
  # 9. nicht gezeigte Dateien werden nicht gemerkt (naechster Zug fragt sie erneut)
  : > "$M"
  ein=$(jbash s13 'grep -rn "func x" server/' 'server/a.go:1:x
server/b.go:2:x')
  h "$ein" MOCK_INDEX_VERSTECKT=1
  h "$ein" MOCK_INDEX_VERSTECKT=1
  { [[ $(grep -c '^index ' "$M") == 2 ]] && grep '^index ' "$M" | tail -n1 | grep -q 'server/b.go'; } \
    && ok "nicht gezeigte Datei wird erneut geliefert" || nein "nicht gezeigt" "$(cat "$M")"

  (( fehler == 0 )) || exit 1
  echo "karte-hinweis: Selbsttest gruen"
  exit 0
fi

tmp=$(mktemp 2>/dev/null) || exit 0
cat > "$tmp" 2>/dev/null || { rm -f "$tmp"; exit 0; }

wurzel=${CLAUDE_PROJECT_DIR:-}
if [[ -z $wurzel ]]; then
  cwd=$(jq -r '.cwd // empty' "$tmp" 2>/dev/null)
  wurzel=$(git -C "${cwd:-.}" rev-parse --show-toplevel 2>/dev/null)
fi
[[ -n $wurzel ]] || { rm -f "$tmp"; exit 0; }

vorab=${DS_KARTE_HINWEIS:-}
if [[ -r $wurzel/ds/projekt.sh ]]; then
  set +u
  . "$wurzel/ds/projekt.sh" 2>/dev/null || true
  set -u
fi
[[ -n $vorab ]] && DS_KARTE_HINWEIS=$vorab   # Umgebung hat Vorrang vor projekt.sh
[[ ${DS_KARTE_HINWEIS:-an} == aus ]] && { rm -f "$tmp"; exit 0; }

karte=${DS_KARTE:-$wurzel/ds/karte}
[[ -x $karte ]] || { rm -f "$tmp"; exit 0; }

DS_HINWEIS_EIN=$tmp DS_HINWEIS_WURZEL=$wurzel DS_HINWEIS_KARTE=$karte \
  python3 - 2>/dev/null <<'PY' || true
import datetime, json, os, re, shlex, subprocess, sys

W = os.environ.get("DS_HINWEIS_WURZEL") or ""
K = os.environ.get("DS_HINWEIS_KARTE") or ""
CODE = (".go", ".gd", ".py")
GRENZE = 9000
KOPF = ("ds/karte -- Funktionsgrenzen (Zeilen Stand jetzt) und Verwendungen; "
        "gezielt lesen mit sed -n von,bisp:")
SCHLUESSEL = ("func", "static", "def", "class", "signal", "const", "var", "type")

def rel_code(pfad, cwd):
    """Absoluter Pfad unter der Wurzel -> relativer Code-Pfad, sonst None."""
    if not pfad or not isinstance(pfad, str) or not pfad.endswith(CODE):
        return None
    p = pfad if os.path.isabs(pfad) else os.path.join(cwd or W, pfad)
    try:
        r = os.path.relpath(os.path.normpath(p), W)
    except ValueError:
        return None
    return None if r == ".." or r.startswith(".." + os.sep) else r

def bash_teile(cmd):
    """Befehl an && || ; | Zeilenumbruch teilen (ausserhalb von Quotes);
    VAR=wert am Anfang und fuehrendes cd <dir> je Teil ueberspringen."""
    teile, akt, quote, i = [], "", None, 0
    while i < len(cmd):
        ch, zwei = cmd[i], cmd[i:i + 2]
        if quote:
            akt += ch
            if ch == quote:
                quote = None
        elif ch in "\"'":
            quote, akt = ch, akt + ch
        elif zwei in ("&&", "||"):
            teile.append(akt); akt = ""; i += 2; continue
        elif ch in ";|\n":
            teile.append(akt); akt = ""
        else:
            akt += ch
        i += 1
    teile.append(akt)
    ergebnis = []
    for teil in teile:
        try:
            w = shlex.split(teil)
        except ValueError:
            w = teil.split()
        while w:
            if re.match(r"^\w+=", w[0]):
                w = w[1:]
            elif w[0] == "cd":
                w = w[2:] if len(w) > 1 else []
            else:
                break
        if w:
            ergebnis.append(w)
    return ergebnis

def lese_dateien(w):
    return [x for x in w[1:] if x.endswith(CODE) and not x.startswith("-")]

def doku(w):
    return any(x.startswith("memory") or x.endswith(".md") for x in w[1:])

def grep_muster(w):
    """Erstes Nicht-Options-Argument, oder das nach -e/--regexp."""
    i = 0
    while i < len(w):
        x = w[i]
        if x in ("-e", "--regexp"):
            return w[i + 1] if i + 1 < len(w) else None
        if x.startswith("--regexp="):
            return x.split("=", 1)[1]
        if x.startswith("-"):
            i += 1
            continue
        return x
    return None

def bezeichner(muster):
    """Gesuchte Bezeichner aus einem Suchmuster (max. 3 Alternativen)."""
    if not muster or not isinstance(muster, str):
        return []
    raus = []
    for t in re.split(r"\\\||\|", muster)[:3]:
        for stueck in (r"\b", r"\s*", r"\(", "^", "$", "(", ")", '"', "'"):
            t = t.replace(stueck, " ")
        t = re.sub(r"^(?:" + "|".join(SCHLUESSEL) + r")\b\s*", "", t.strip()).strip()
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?", t) \
                and len(t) >= 3 and t not in raus:
            raus.append(t)
    return raus

def grep_dateien(text):
    """Code-Dateien aus grep-Ausgabe: pfad:zeile: / pfad:zeile- / pfad-zeile- / reiner Pfad."""
    z = {}
    for zeile in (text or "").splitlines():
        s = zeile.strip()
        if not s:
            continue
        m = re.match(r"^(.+?\.(?:go|gd|py))[-:]\d+[-:]", s)
        p = m.group(1) if m else s
        if p.endswith(CODE):
            z[p] = z.get(p, 0) + 1
    return z

def index_parse(text):
    """Aus der index-Ausgabe: gelieferte bzw. 'nicht gezeigt' Dateien."""
    gel, versteckt = set(), set()
    for zeile in (text or "").splitlines():
        s = zeile.strip()
        if "nicht gezeigt" in s:
            versteckt.update(re.findall(r"[A-Za-z0-9_./-]+\.(?:go|gd|py)", s))
            continue
        m = re.match(r"^(\S+?\.(?:go|gd|py)):", s)
        if m:
            gel.add(m.group(1))
    return gel - versteckt, versteckt

def schreibe_atomar(pfad, inhalt):
    try:
        tmp = pfad + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(inhalt, f, ensure_ascii=False)
        os.replace(tmp, pfad)
    except OSError:
        pass

def jetzt():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def haupt():
    try:
        with open(os.environ["DS_HINWEIS_EIN"], encoding="utf-8", errors="replace") as f:
            o = json.load(f)
    except Exception:
        return
    if not isinstance(o, dict):
        return
    sid = re.sub(r"[^A-Za-z0-9._-]", "-", str(o.get("session_id") or "")) or "ohne-sitzung"
    cwd = o.get("cwd") or W
    name = o.get("tool_name") or ""
    inp = o.get("tool_input") or {}
    resp = o.get("tool_response")
    resp_text = resp if isinstance(resp, str) else json.dumps(resp, ensure_ascii=False)
    aus_bash = resp.get("stdout", "") if isinstance(resp, dict) else resp_text

    direkt, treffer, namen = [], {}, []

    def merke_direkt(p):
        if p and p not in direkt:
            direkt.append(p)

    def merke_treffer(p, n=1):
        if p:
            treffer[p] = treffer.get(p, 0) + n

    if name == "Read":
        merke_direkt(rel_code(inp.get("file_path", ""), cwd))
    elif name == "Bash":
        for w in bash_teile(inp.get("command", "")):
            if w[0] in ("sed", "head", "tail", "awk", "cat", "less"):
                for p in lese_dateien(w):
                    merke_direkt(rel_code(p, cwd))
            elif w[0] in ("grep", "rg", "egrep") or w[:2] == ["git", "grep"]:
                if doku(w):
                    continue
                muster = grep_muster(w[2:] if w[:2] == ["git", "grep"] else w[1:])
                for b in bezeichner(muster):
                    if b not in namen:
                        namen.append(b)
                for p, n in grep_dateien(aus_bash).items():
                    merke_treffer(rel_code(p, cwd), n)
                if aus_bash.strip():   # grep -n X datei.gd: Treffer ohne Dateinamen
                    for p in lese_dateien(w):
                        merke_treffer(rel_code(p, cwd))
    elif name == "Grep":
        ziel = str(inp.get("path", "")) + " " + str(inp.get("glob", ""))
        if not re.search(r"memory|\.md\b", ziel):
            for b in bezeichner(inp.get("pattern")):
                if b not in namen:
                    namen.append(b)
            for p in re.findall(r"[A-Za-z0-9_./-]+\.(?:go|gd|py)", resp_text):
                merke_treffer(rel_code(p, cwd))

    reihenfolge = list(direkt)
    for p in sorted(treffer, key=lambda x: -treffer[x]):
        if p not in reihenfolge:
            reihenfolge.append(p)
    reihenfolge = reihenfolge[:8]

    verz = os.path.join(W, "ds", "arbeit", ".karte-hinweis")
    try:
        os.makedirs(verz, exist_ok=True)
    except OSError:
        pass
    gm = os.path.join(verz, sid + ".json")
    daten = {"dateien": {}, "namen": []}
    try:
        with open(gm, encoding="utf-8") as f:
            d = json.load(f)
        if isinstance(d, dict):
            if isinstance(d.get("dateien"), dict):
                daten["dateien"] = d["dateien"]
            if isinstance(d.get("namen"), list):
                daten["namen"] = d["namen"]
    except Exception:
        pass

    neu = []
    for p in reihenfolge:
        try:
            mt = os.stat(os.path.join(W, p)).st_mtime_ns
        except OSError:
            continue
        if daten["dateien"].get(p) != mt:
            neu.append((p, mt))
    neue_namen = [n for n in namen if n not in daten["namen"]]
    if not neu and not neue_namen:
        return

    def ruf(args):
        try:
            return subprocess.run([K] + args, cwd=W, capture_output=True, text=True, timeout=5)
        except Exception:
            return None

    index_text = ""
    if neu:
        r = ruf(["index", "--max-zeichen", "6000"] + [p for p, _ in neu])
        if r is not None and r.returncode == 0 and (r.stdout or "").strip():
            index_text = r.stdout.strip()
    verwendungen = []
    for n in neue_namen:
        r = ruf(["verwendung", "--max-zeichen", "2500", n])
        if r is not None and r.returncode == 0 and (r.stdout or "").strip():
            verwendungen.append((n, r.stdout.strip()))

    index_teil = ""
    if index_text:
        platz = GRENZE - len(KOPF) - 1
        index_teil = index_text[:platz] if platz > 0 else ""
    text = KOPF + ("\n" + index_teil if index_teil else "")
    benutzte_namen, gekappt = [], False
    for n, ausgabe in verwendungen:
        zusatz = "\n" + ausgabe
        platz = GRENZE - len(text)
        if platz <= 0:
            gekappt = True
            break
        if len(zusatz) > platz:
            text += zusatz[:platz]           # hart auf 9000 kappen, Name nicht merken
            gekappt = True
            break
        text += zusatz
        benutzte_namen.append(n)
    if not index_teil and not benutzte_namen and not gekappt:
        return

    geliefert, _ = index_parse(index_teil)
    dateien_neu = dict(daten["dateien"])
    for p, mt in neu:
        if p in geliefert:
            dateien_neu[p] = mt            # nur was wirklich in der Ausgabe stand
    namen_neu = list(daten["namen"])
    for n in benutzte_namen:
        if n not in namen_neu:
            namen_neu.append(n)
    schreibe_atomar(gm, {"dateien": dateien_neu, "namen": namen_neu})

    log = os.path.join(verz, sid + ".log.jsonl")
    try:
        with open(log, "a", encoding="utf-8") as f:
            f.write(json.dumps({"ts": jetzt(), "tool_use_id": o.get("tool_use_id"),
                                "dateien": sorted(geliefert), "namen": benutzte_namen,
                                "zeichen": len(text), "text": text}, ensure_ascii=False) + "\n")
    except OSError:
        pass

    sys.stdout.write(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PostToolUse", "additionalContext": text}}, ensure_ascii=False))

try:
    haupt()
except Exception:
    pass
PY

rm -f "$tmp"
exit 0
