#!/usr/bin/env python3
"""Token und Kosten eines DeepSeek-Arbeitsblocks auf allen drei Ebenen.

  python3 ds/tokens.py <name> [--sitzung <id>] [--seit <ISO-Zeit>] [--json]
  python3 ds/tokens.py --karte    Erkundung aller Laeufe: ohne / mit ds/karte

Opus      Hauptsitzung (Transkript ~/.claude/projects/<repo>/<sitzung>.jsonl):
          Steuerung = Aufrufe, deren Tool-Eingaben <name> nennen (Auftrag,
          warte, diff, uebernehmen ...). Nennt ein Aufruf mehrere Auftraege
          (parallele Briefe), zaehlt er anteilig -- so ueberlappen parallele
          Laeufe nicht.
          Vorbereitung = Aufrufe ohne Auftragsnamen von der letzten
          Nutzernachricht vor dem ersten Aufruf, der <name> nennt, bis zum
          Bauleiter-Start (Code erkunden, Auftrag denken, Rueckfragen).
          Fruehere Zuege zaehlen nicht mit; entstehen mehrere Auftraege im
          selben Zug, teilen sie sich die Vorbereitung. Ohne diese Zeile fehlte
          z. B. bei tempo-v7 gut ein Drittel des Opus-Anteils (2026-10-04).
Erkundung Werkzeugaufrufe von Opus in Vorbereitung + Steuerung: ds/karte
          (Aufrufe, Token), Code (.go/.gd/.py) ganz/gezielt gelesen, Suchen
          (Grep, grep/rg). "gezielt nach Karte" = Read mit offset/limit einer
          Datei, die eine fruehere Karten-Ausgabe nannte (Karte hat geholfen);
          "ganz trotz Karte" = sie hat das Lesen nicht ersetzt. "Potenzial" =
          ganz gelesene Code-Dateien minus ihre heutige Gliederung (Schaetzung,
          was die Karte gespart haette). Token = Zeichen / DS_ZEICHEN_JE_TOKEN.
          Karte-Hinweis (Hook karte-hinweis.sh, ds/arbeit/.karte-hinweis/*.log.jsonl,
          Zuordnung ueber tool_use_id): "in Grenzen" = gezielte Lesezugriffe, deren
          Bereich eine im Hinweis gelieferte Symbol-Spanne trifft, von allen
          gezielten Zugriffen auf eine gelieferte Datei (gezielt_geliefert).
          "Erkundungszuege" = Opus-Aufrufe mit Karte/Lesen/Suchen und ihre
          Kosten: jeder Zug liest den Sitzungskontext neu, das kostet meist
          mehr als das Gelesene selbst (Basis 61 Laeufe: ~6k Token Ergebnis,
          0,35 $ Vorbereitung je Lauf). Hilft die Karte, sinkt diese Zahl.
Bauleiter alle Subagenten der Sitzung, deren Brief "Name: <name>" enthaelt.
DeepSeek  ds/arbeit/<name>.laeufe.jsonl (eine Zeile je ds-worker-Lauf).

Aufrufe werden ueber message.id entdoppelt (ein Aufruf steht je Inhaltsblock
mehrfach im Transkript). Preise: PREISE unten -- vor Gebrauch pruefen!

Ersparnis (Hauptzahl): geschaetzte Kosten, wenn
Opus den Auftrag direkt in der Hauptsitzung gebaut haette, minus die
tatsaechlichen Delegationskosten (Opus-Steuerung + Bauleiter + DeepSeek).
Modell der Direktumsetzung: Opus braucht 35-70 % der DeepSeek-Zuege; jeder Zug
liest den Sitzungskontext beim Brief (ctx) plus die Haelfte des neu gelesenen
Codes aus dem Cache; der neu gelesene Code (DeepSeek-Eingabe ohne Cache) wird
einmal in den 1-h-Cache geschrieben; die Ausgabe entspricht der von DeepSeek.
"""
import argparse, glob, json, os, re, shlex, subprocess, sys

# je 1M Token in USD: ein, cache lesen, cache schreiben 5 min, 1 h, aus
# Stand 2026-10 (Anthropic-Preisliste, DeepSeek-Dashboard Off-Peak). Pruefen!
PREISE = {
    "claude-opus":    (4.00, 0.20, 5.00, 8.00, 20.00),
    "claude-sonnet":  (2.00, 0.20, 2.50, 4.00, 10.00),
    "claude-haiku":   (1.00, 0.10, 1.25, 2.00, 5.00),
    "deepseek-flash": (0.15, 0.003, 0.15, 0.15, 0.60),
}

def preis(modell):
    for k, p in PREISE.items():
        if modell.startswith(k):
            return p
    return None

def leer():
    return {"aufrufe": 0, "ein": 0, "cr": 0, "cw5": 0, "cw1h": 0, "aus": 0, "modelle": set()}

def addiere(s, u, modell):
    cc = u.get("cache_creation") or {}
    cw1h = cc.get("ephemeral_1h_input_tokens", 0)
    cw5 = cc.get("ephemeral_5m_input_tokens", u.get("cache_creation_input_tokens", 0) - cw1h)
    s["aufrufe"] += 1
    s["ein"] += u.get("input_tokens", 0)
    s["cr"] += u.get("cache_read_input_tokens", 0)
    s["cw5"] += cw5
    s["cw1h"] += cw1h
    s["aus"] += u.get("output_tokens", 0)
    s["modelle"].add(modell)

def kosten(s, modell):
    p = preis(modell)
    if not p:
        return None
    return (s["ein"] * p[0] + s["cr"] * p[1] + s["cw5"] * p[2] + s["cw1h"] * p[3] + s["aus"] * p[4]) / 1e6

def transkript(pfad, seit=None):
    """Summe je Modell; nur Hauptkette, Aufrufe entdoppelt (letzter Eintrag gilt)."""
    aufrufe = {}
    for zeile in open(pfad, encoding="utf-8"):
        try:
            o = json.loads(zeile)
        except ValueError:
            continue
        m = o.get("message") or {}
        if o.get("type") != "assistant" or not m.get("usage") or m.get("model") == "<synthetic>":
            continue
        if seit and o.get("timestamp", "") < seit:
            continue
        aufrufe[m.get("id") or o.get("uuid")] = (m["model"], m["usage"])
    je = {}
    for modell, u in aufrufe.values():
        addiere(je.setdefault(modell, leer()), u, modell)
    return je

def nutzer_text(o):
    """Echte Nutzernachricht (kein Werkzeug-Ergebnis, keine Systemmeldung)?"""
    if o.get("type") != "user" or o.get("isMeta") or o.get("isCompactSummary"):
        return False
    c = (o.get("message") or {}).get("content")
    texte = [c] if isinstance(c, str) else [b.get("text", "") for b in c or []
                                            if isinstance(b, dict) and b.get("type") == "text"]
    return any(t.strip() and not t.lstrip().startswith(("<task-notification", "[SYSTEM NOTIFICATION",
                                                         "<local-command", "<command-name>",
                                                         "Another Claude session sent a message"))
               for t in texte)

def steuerung(pfad, name, namen):
    """Opus-Aufrufe, deren Tool-Eingaben <name> nennen, anteilig je genannter
    Auftraege, und die Vorbereitung davor (s. Kopf).
    Rueckgabe: (Steuerung je Modell, Vorbereitung je Modell, ctx des ersten
    Aufrufs, Anteil je message-id beider Fenster)."""
    inhalt, usage, nutzer = {}, {}, []
    for zeile in open(pfad, encoding="utf-8"):
        try:
            o = json.loads(zeile)
        except ValueError:
            continue
        if nutzer_text(o):
            nutzer.append(o.get("timestamp", ""))
            continue
        m = o.get("message") or {}
        if o.get("type") != "assistant" or not m.get("usage") or m.get("model") == "<synthetic>":
            continue
        k = m.get("id") or o.get("uuid")
        usage[k] = (m["model"], m["usage"], o.get("timestamp", ""))
        for b in m.get("content") or []:
            if isinstance(b, dict) and b.get("type") == "tool_use":
                inhalt[k] = inhalt.get(k, "") + json.dumps(b.get("input"), ensure_ascii=False)
    je, vor, ctx, fenster = {}, {}, None, {}
    wort = lambda n: re.compile(r"(?<![a-z0-9-])" + re.escape(n) + r"(?![a-z0-9-])")
    muster = {n: wort(n) for n in namen}
    folge = sorted(usage.items(), key=lambda x: x[1][2])
    genannt = {k: [n for n, rx in muster.items() if rx.search(inhalt.get(k, ""))] for k, _ in folge}
    for k, (modell, u, ts) in folge:
        if name not in genannt[k]:
            continue
        if ctx is None:
            ctx = u.get("input_tokens", 0) + u.get("cache_read_input_tokens", 0) + u.get("cache_creation_input_tokens", 0)
        dazu(je, modell, u, 1.0 / len(genannt[k]))
        fenster[k] = 1.0 / len(genannt[k])

    # Vorbereitung: von der letzten Nutzernachricht vor dem ersten Aufruf, der
    # <name> nennt, bis zum Start des Bauleiters ("Name: <name>"): alle
    # Aufrufe, die keinen Auftrag nennen (die zaehlen schon als Steuerung).
    erst, start = {}, {}
    for k, (modell, u, ts) in folge:
        for n in genannt[k]:
            erst.setdefault(n, ts)
            if f"Name: {n}" in inhalt.get(k, ""):
                start.setdefault(n, ts)
    if name in erst:
        zug = lambda t: max((x for x in nutzer if x < t), default="")
        beginn, ende = zug(erst[name]), start.get(name, erst[name])
        # Teilen nur mit Auftraegen, die im selben Zug gestartet wurden (nur
        # gelesene alte Auftraege, z. B. als Muster, zaehlen nicht).
        teiler = sum(1 for n, t in erst.items() if n in start and zug(t) == beginn) or 1
        for k, (modell, u, ts) in folge:
            if beginn < ts < ende and not genannt[k]:
                dazu(vor, modell, u, 1.0 / teiler)
                fenster[k] = 1.0 / teiler
    return je, vor, ctx or 0, fenster

CODE = (".go", ".gd", ".py")
ZJT = float(os.environ.get("DS_ZEICHEN_JE_TOKEN", "2.66").replace(",", "."))

def karte_binary(repo):
    hier = os.path.dirname(os.path.abspath(__file__))
    for k in (os.path.join(repo, "ds/karte"), os.path.join(hier, "karte"),
              os.path.join(hier, "../../karte/karte")):  # Modul-Checkout
        if os.access(k, os.X_OK):
            return k
    return None

def shell_art(cmd):
    """Bash-Aufruf einordnen: (karte|ganz|gezielt|suchen|None, Code-Dateien).
    Opus liest oft per Shell (cd repo; sed -n a,bp datei; grep ...)."""
    if re.search(r"(^|[\s;&|(/])ds/karte\b", cmd):
        return "karte", []
    art, dateien = None, []
    for teil in re.split(r"&&|\|\||[;|\n]", cmd):
        try:
            w = shlex.split(teil)
        except ValueError:
            w = teil.split()
        while w and re.match(r"^\w+=", w[0]):   # VAR=wert befehl
            w = w[1:]
        if not w:
            continue
        code = [x for x in w[1:] if x.endswith(CODE) and not x.startswith("-")]
        if w[0] in ("sed", "head", "tail", "awk") and code:
            art, dateien = "ganz" if art == "ganz" else "gezielt", dateien + code
        elif w[0] in ("cat", "less") and code:
            art, dateien = "ganz", dateien + code
        elif (w[0] in ("grep", "rg", "egrep") or w[:2] == ["git", "grep"]) and \
                not any(re.match(r"memory\b|.*\.md$", x) for x in w[1:]):   # Gedaechtnis/Doku: kein Code
            art = art or "suchen"
    return art, dateien

def hinweis_log(repo, sitzung="*"):
    """Protokollzeilen des Hooks karte-hinweis.sh einer Sitzung, nach Zeit sortiert.
    Je Zeile: tool_use_id, dateien, namen, zeichen, text (s. Hook)."""
    eintraege = []
    for f in sorted(glob.glob(os.path.join(repo, f"ds/arbeit/.karte-hinweis/{sitzung}.log.jsonl"))):
        try:
            for zeile in open(f, encoding="utf-8", errors="replace"):
                try:
                    o = json.loads(zeile)
                except ValueError:
                    continue
                if isinstance(o, dict) and o.get("tool_use_id"):
                    eintraege.append(o)
        except OSError:
            continue
    eintraege.sort(key=lambda o: o.get("ts", ""))
    return eintraege

def hinweis_spannen(text):
    """Gelieferte Symbol-Spannen je Datei aus einem Hinweistext: index-Zeilen
    'pfad: Name von-bis, ...' -> {pfad: [(von, bis), ...]}."""
    spannen = {}
    for zeile in (text or "").splitlines():
        m = re.match(r"^\s*(\S+?\.(?:go|gd|py)):(.*)$", zeile)
        if not m:
            continue
        paare = re.findall(r"(\d+)\s*-\s*(\d+)", m.group(2))
        if paare:
            spannen.setdefault(m.group(1), []).extend((int(a), int(b)) for a, b in paare)
    return spannen

def gezielt_bereich(name, inp):
    """Bereich (Datei, a, b) eines gezielten Lesezugriffs, sonst None.
    Read mit offset/limit; Bash: sed -n a,bp (head/tail ohne Bereich zaehlen nicht)."""
    if name == "Read":
        if inp.get("offset") is not None or inp.get("limit") is not None:
            a = int(inp.get("offset") or 0)
            lim = inp.get("limit")
            return inp.get("file_path", ""), a, a + int(lim) - 1 if lim else a
        return None
    if name == "Bash":
        for teil in re.split(r"&&|\|\||[;|\n]", inp.get("command", "")):
            try:
                w = shlex.split(teil)
            except ValueError:
                w = teil.split()
            if not w or w[0] != "sed":
                continue
            m = re.search(r"(\d+)\s*,\s*(\d+)p", teil)
            datei = next((x for x in w[1:] if x.endswith(CODE) and not x.startswith("-")), None)
            if m and datei:
                return datei, int(m.group(1)), int(m.group(2))
    return None

def in_grenzen(a, b, spannen):
    """Trifft der gezielte Lesebereich (a,b) eine gelieferte Symbol-Spanne?
    spannen: [(von, bis), ...] aus dem Karte-Hinweis."""
    return any(abs(a - von) <= 3 and von <= b <= bis + 30 for von, bis in spannen)

def erkundung(pfad, fenster, repo):
    """Lesen und Karte in den Opus-Aufrufen des Fensters (s. Kopf)."""
    aufrufe, ergebnis, usage = [], {}, {}
    for zeile in open(pfad, encoding="utf-8"):
        try:
            o = json.loads(zeile)
        except ValueError:
            continue
        m = o.get("message") or {}
        for b in m.get("content") or []:
            if not isinstance(b, dict):
                continue
            k = m.get("id") or o.get("uuid")
            if b.get("type") == "tool_use" and k in fenster:
                aufrufe.append((o.get("timestamp", ""), b, fenster[k], k))
                usage[k] = (m.get("model", ""), m.get("usage") or {})
            elif b.get("type") == "tool_result":
                c = b.get("content")
                ergebnis[b.get("tool_use_id")] = c if isinstance(c, str) else "".join(
                    x.get("text", "") for x in c or [] if isinstance(x, dict))
    e = {"karte": 0, "karte_befehle": {}, "karte_token": 0, "ganz": 0, "ganz_token": 0,
         "gezielt": 0, "gezielt_token": 0, "gezielt_nach_karte": 0, "ganz_trotz_karte": 0,
         "suchen": 0, "suchen_token": 0, "potenzial": 0, "zuege": 0, "zuege_kosten": 0,
         "hinweise": 0, "hinweis_token": 0, "in_grenzen": 0, "gezielt_geliefert": 0}
    logs = hinweis_log(repo, os.path.basename(pfad)[:-len(".jsonl")])   # nur diese Sitzung
    logs_je = {o["tool_use_id"]: o for o in logs}
    dateien_je = {o["tool_use_id"]: set(o.get("dateien") or []) for o in logs}
    spannen_je = {o["tool_use_id"]: hinweis_spannen(o.get("text", "")) for o in logs}
    erkundend = {}   # message-id -> Anteil: Zuege mit Karte/Lesen/Suchen
    gesehen, ganz = "", set()   # gesammelte Karten-Ausgaben; ganz gelesene Code-Dateien
    for ts, b, g, mk in sorted(aufrufe, key=lambda x: x[0]):   # g: Anteil dieses Auftrags
        inp, text = b.get("input") or {}, ergebnis.get(b.get("id"), "")
        tok = len(text) / ZJT * g
        hle = logs_je.get(b.get("id"))
        if hle:   # dieser Aufruf hat einen Karte-Hinweis bekommen
            e["hinweise"] += g
            e["hinweis_token"] += (hle.get("zeichen") or len(hle.get("text", ""))) / ZJT * g
        if b.get("name") == "Read":
            fp = inp.get("file_path", "")
            art, dateien = ("gezielt" if inp.get("offset") or inp.get("limit") else "ganz"), [fp]
            art = art if fp.endswith(CODE) else None
        elif b.get("name") == "Grep":
            ziel = inp.get("path", "") + " " + inp.get("glob", "")
            art, dateien = (None if re.search(r"memory|\.md\b", ziel) else "suchen"), []
        elif b.get("name") == "Bash":
            art, dateien = shell_art(inp.get("command", ""))
        else:
            continue
        rels = [os.path.relpath(os.path.join(repo, d), repo) for d in dateien]
        if art:
            erkundend[mk] = g
        if art == "karte":
            e["karte"] += g
            e["karte_token"] += tok
            w = re.search(r"ds/karte\s+(\w+)", inp.get("command", ""))
            w = w.group(1) if w else "?"
            e["karte_befehle"][w] = e["karte_befehle"].get(w, 0) + g
            gesehen += inp.get("command", "") + "\n" + text
        elif art in ("ganz", "gezielt"):
            karte_kennt = any(r in gesehen for r in rels)
            e[art] += g
            e[art + "_token"] += tok
            e["gezielt_nach_karte" if art == "gezielt" else "ganz_trotz_karte"] += karte_kennt * g
            if art == "gezielt":
                gb = gezielt_bereich(b.get("name"), inp)
                if gb:
                    datei, a, bis = gb
                    rel = os.path.relpath(os.path.join(repo, datei), repo)
                    frueher = [o for o in logs if o.get("ts", "") < ts]
                    if any(rel in dateien_je[o["tool_use_id"]] for o in frueher):
                        e["gezielt_geliefert"] += g          # Nenner: gezielt auf gelieferte Datei
                        sp = [p for o in frueher if rel in dateien_je[o["tool_use_id"]]
                              for p in spannen_je[o["tool_use_id"]].get(rel, [])]
                        if sp and in_grenzen(a, bis, sp):
                            e["in_grenzen"] += g             # genau in gelieferte Symbolgrenzen
            if art == "ganz":
                ganz.update((r, tok / len(rels)) for r in rels if not r.startswith(".."))
        elif art == "suchen":
            e["suchen"] += g
            e["suchen_token"] += tok
    for mk, g in erkundend.items():   # ein Zug liest den ganzen Kontext neu: das kostet
        einzeln = leer()
        addiere(einzeln, usage[mk][1], usage[mk][0])
        e["zuege"] += g
        e["zuege_kosten"] += (kosten(einzeln, usage[mk][0]) or 0) * g
    e["zuege_kosten"] = round(e["zuege_kosten"], 3)
    k = karte_binary(repo)
    for rel, tok in ganz:
        if k and os.path.exists(os.path.join(repo, rel)):
            r = subprocess.run([k, "gliederung", rel], cwd=repo, capture_output=True, text=True)
            if r.returncode == 0:
                e["potenzial"] += max(0, tok - len(r.stdout) / ZJT)
    for f in ("karte_token", "ganz_token", "gezielt_token", "suchen_token", "potenzial", "hinweis_token"):
        e[f] = round(e[f])
    for f in ("karte", "ganz", "gezielt", "suchen", "gezielt_nach_karte", "ganz_trotz_karte", "zuege",
              "hinweise", "in_grenzen", "gezielt_geliefert"):
        e[f] = round(e[f], 1)
    e["karte_befehle"] = {w: round(n, 1) for w, n in e["karte_befehle"].items()}
    return e

def dazu(ziel, modell, u, anteil):
    z = ziel.setdefault(modell, leer())
    einzeln = leer()
    addiere(einzeln, u, modell)
    for f in ("aufrufe", "ein", "cr", "cw5", "cw1h", "aus"):
        z[f] += einzeln[f] * anteil
    z["modelle"].add(modell)

def direkt(ds, ctx, anteil):
    """Geschaetzte Opus-Kosten der Direktumsetzung (Modell s. Kopf)."""
    p = preis("claude-opus")
    zuege = ds["aufrufe"] * anteil
    neu = ds["ein"]
    return (zuege * (ctx + neu / 2) * p[1] + neu * p[3] + ds["aus"] * p[4]) / 1e6

KURS_EUR = 0.86  # Annahme EUR je USD, Stand 2026-10

def erster_zeitstempel(pfad):
    for zeile in open(pfad, encoding="utf-8"):
        try:
            ts = json.loads(zeile).get("timestamp")
        except ValueError:
            continue
        if ts:
            return ts
    return None

def de(x, stellen=2):
    return f"{x:.{stellen}f}".replace(".", ",")

def mio(n):
    n = round(n)
    if n >= 1e5:
        return de(n / 1e6) + " Mio."
    return f"{round(n / 1e3):,}".replace(",", ".") + "k" if n >= 1e3 else str(n)

def karte_bilanz(repo):
    """--karte: Erkundung je Lauf (ds/arbeit/*.laeufe.jsonl), Summen getrennt
    nach Laeufen ohne und mit ds/karte-Aufruf, je Lauf gemittelt."""
    zeilen = []
    for f in sorted(glob.glob(os.path.join(repo, "ds/arbeit/*.laeufe.jsonl")), key=os.path.getmtime):
        n = os.path.basename(f)[:-len(".laeufe.jsonl")]
        r = subprocess.run([sys.executable, os.path.abspath(__file__), n, "--json"],
                           capture_output=True, text=True, env=dict(os.environ, DS_REPO=repo))
        if r.returncode == 0:
            zeilen.append(json.loads(r.stdout))
    print("| Lauf | Vorbereitung | Erkundungszuege | Karte | Hinweise | in Grenzen | Code ganz | gezielt (nach Karte) | Suchen | Potenzial |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    gruppen = {"ohne": [], "mit": []}
    for z in zeilen:
        e, vor = z["erkundung"], z["kosten"].get("Opus-Vorbereitung", 0)
        gruppen["mit" if e["karte"] or e["hinweise"] else "ohne"].append(z)
        if e["karte"] or e["hinweise"] or e["ganz"] or e["gezielt"] or e["suchen"]:
            print(f"| {z['name']} | {de(vor)} $ | {de(e['zuege'], 0)} {de(e['zuege_kosten'])} $ | {de(e['karte'], 0)}x {mio(e['karte_token'])} | "
                  f"{de(e['hinweise'], 0)}x {mio(e['hinweis_token'])} | {de(e['in_grenzen'], 0)}/{de(e['gezielt_geliefert'], 0)} | "
                  f"{de(e['ganz'], 0)}x {mio(e['ganz_token'])} | {de(e['gezielt'], 0)}x {mio(e['gezielt_token'])}"
                  f" ({de(e['gezielt_nach_karte'], 0)}) | {de(e['suchen'], 0)}x {mio(e['suchen_token'])} | "
                  f"{mio(e['potenzial'])} |")
    print()
    print("Je Lauf gemittelt (Token = Ergebnisse im Opus-Kontext):")
    print("| Gruppe | Laeufe | Vorbereitung | Erkundungszuege | Karte-Token | Hinweise | in Grenzen x/y | Code gelesen | Suchen | ganz trotz Karte |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for g, zs in gruppen.items():
        if not zs:
            continue
        m = lambda f: sum(z["erkundung"][f] for z in zs) / len(zs)
        print(f"| {g} ds/karte | {len(zs)} | {de(sum(z['kosten'].get('Opus-Vorbereitung', 0) for z in zs) / len(zs))} $ | "
              f"{de(m('zuege'), 1)} {de(m('zuege_kosten'))} $ | "
              f"{mio(m('karte_token'))} | {de(m('hinweise'), 1)}x {mio(m('hinweis_token'))} | "
              f"{de(m('in_grenzen'), 1)}/{de(m('gezielt_geliefert'), 1)} | "
              f"{mio(m('ganz_token') + m('gezielt_token'))} | "
              f"{de(m('suchen'), 1)}x {mio(m('suchen_token'))} | {de(m('ganz_trotz_karte'), 1)}x |")

def main():
    if sys.argv[1:] == ["--karte"]:
        return karte_bilanz(os.environ.get("DS_REPO") or os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ap = argparse.ArgumentParser()
    ap.add_argument("name")
    ap.add_argument("--sitzung")
    ap.add_argument("--seit")
    ap.add_argument("--json", action="store_true", help="Kennzahlen als JSON (Auswertung)")
    a = ap.parse_args()

    repo = os.environ.get("DS_REPO") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    projekt = os.path.expanduser("~/.claude/projects/" + re.sub(r"[^A-Za-z0-9]", "-", repo))
    if a.sitzung:
        haupt = os.path.join(projekt, a.sitzung + ".jsonl")
    else:  # die Sitzung mit einem Bauleiter fuer <name>, sonst die juengste
        kandidaten = sorted(glob.glob(projekt + "/*.jsonl"), key=os.path.getmtime, reverse=True)
        haupt = next((k for k in kandidaten if glob.glob(k[:-6] + "/subagents/*.jsonl")
                      and any(f"Name: {a.name}" in open(f, encoding="utf-8").read(20000)
                              for f in glob.glob(k[:-6] + "/subagents/agent-*.jsonl"))),
                     kandidaten[0] if kandidaten else None)
    if not haupt or not os.path.exists(haupt):
        sys.exit("kein Sitzungs-Transkript gefunden")

    bauleiter = [f for f in glob.glob(haupt[:-6] + "/subagents/agent-*.jsonl")
                 if f"Name: {a.name}" in open(f, encoding="utf-8").read(20000)]
    seit = a.seit or min(filter(None, map(erster_zeitstempel, bauleiter)), default=None)

    namen = {os.path.basename(f)[:-len(".auftrag.md")]
             for f in glob.glob(os.path.join(repo, "ds/arbeit/*.auftrag.md"))} | {a.name}
    zeilen = []  # (Ebene, Modell, Summe)
    vor = {}
    if a.seit:  # alte Zaehlung: alles ab Zeitpunkt (nur fuer Nachmessungen)
        opus, ctx, fenster = transkript(haupt, a.seit), 0, {}
    else:
        opus, vor, ctx, fenster = steuerung(haupt, a.name, namen)
    erk = erkundung(haupt, fenster, repo)
    for modell, s in vor.items():
        zeilen.append(("Opus-Vorbereitung", modell, s))
    for modell, s in opus.items():
        zeilen.append(("Opus-Steuerung", modell, s))
    bl = {}
    for f in bauleiter:
        for modell, s in transkript(f).items():
            z = bl.setdefault(modell, leer())
            for k in ("aufrufe", "ein", "cr", "cw5", "cw1h", "aus"):
                z[k] += s[k]
    for modell, s in bl.items():
        zeilen.append((f"Bauleiter ({len(bauleiter)} Start{'s' if len(bauleiter) != 1 else ''})", modell, s))

    ds = leer()
    laeufe = os.path.join(repo, "ds/arbeit", a.name + ".laeufe.jsonl")
    zuege = n = 0
    if os.path.exists(laeufe):
        for zeile in open(laeufe, encoding="utf-8"):
            o = json.loads(zeile)
            u = o.get("usage") or {}
            n += 1
            zuege += o.get("num_turns") or 0
            ds["ein"] += u.get("input_tokens", 0) + (u.get("cache_creation_input_tokens") or 0)
            ds["cr"] += u.get("cache_read_input_tokens", 0)
            ds["aus"] += u.get("output_tokens", 0)
    ds["aufrufe"] = zuege

    ds_modell = os.environ.get("DS_MODEL", "deepseek-flash")
    # Lokales Backend (DS_BACKEND=lokal): keine Kosten je Token; die Ersparnis
    # ist dann die ganze geschaetzte Direktumsetzung minus Opus und Bauleiter.
    lokal = os.environ.get("DS_BACKEND") == "lokal"
    if lokal:
        PREISE[ds_modell] = (0.0, 0.0, 0.0, 0.0, 0.0)
    arbeiter = "Arbeiter lokal" if lokal else "DeepSeek"
    if a.json:
        je = {}
        for ebene, modell, s in zeilen:
            je[ebene.split(" (")[0]] = je.get(ebene.split(" (")[0], 0) + (kosten(s, modell) or 0)
        je["DeepSeek"] = kosten(ds, ds_modell) or 0
        gesamt = sum(je.values())
        print(json.dumps({"name": a.name, "zuege": zuege, "laeufe": n, "ctx": ctx, "kosten": je,
                          "delegation": gesamt, "erkundung": erk, "direkt": [direkt(ds, ctx, 0.35), direkt(ds, ctx, 0.70)]}))
        return
    print(f"Token und Kosten: {a.name}")
    print()
    print("| Ebene | Modell | Aufrufe | Eingabe | Cache gelesen | Cache geschrieben | Ausgabe | Kosten |")
    print("|---|---|---:|---:|---:|---:|---:|---:|")
    summe = 0.0
    for ebene, modell, s in zeilen + [(f"{arbeiter} ({n} {'Lauf' if n == 1 else 'Läufe'}, {zuege} Züge)", ds_modell, ds)]:
        k = kosten(s, modell)
        summe += k or 0
        print(f"| {ebene} | {modell} | {round(s['aufrufe'])} | {mio(s['ein'])} | {mio(s['cr'])} | "
              f"{mio(s['cw5'] + s['cw1h'])} | {mio(s['aus'])} | "
              + (f"≈ {de(k)} $" if k is not None else "Preis fehlt") + " |")
    print(f"| **Delegation gesamt** | | | | | | | **≈ {de(summe)} $** |")
    print()
    lo, hi = direkt(ds, ctx, 0.35), direkt(ds, ctx, 0.70)
    print(f"Direkt durch Opus (Schaetzung, ctx {mio(ctx)}, {round(ds['aufrufe'] * 0.35)}-"
          f"{round(ds['aufrufe'] * 0.7)} Zuege): ≈ {de(lo)}-{de(hi)} $")
    print(f"**Ersparnis durch den Bauleiter: ≈ {de(lo - summe)}-{de(hi - summe)} $ "
          f"(≈ {de((lo - summe) * KURS_EUR)}-{de((hi - summe) * KURS_EUR)} €)**, "
          f"Faktor {de(lo / max(summe, 0.01), 1)}-{de(hi / max(summe, 0.01), 1)}x")
    print()
    e = erk
    befehle = ", ".join(f"{w} {de(n, 0)}" for w, n in sorted(e["karte_befehle"].items()))
    print(f"Erkundung (Opus): ds/karte {de(e['karte'], 0)}x" + (f" ({befehle}, {mio(e['karte_token'])} Token)" if e["karte"] else "")
          + f"; Code ganz gelesen {de(e['ganz'], 0)}x ({mio(e['ganz_token'])}), gezielt {de(e['gezielt'], 0)}x ({mio(e['gezielt_token'])}); "
          f"Suchen {de(e['suchen'], 0)}x ({mio(e['suchen_token'])})")
    print(f"  Erkundungszuege: {de(e['zuege'], 0)} (≈ {de(e['zuege_kosten'])} $)")
    if e["hinweise"]:
        print(f"  Karte-Hinweis: {de(e['hinweise'], 0)}x (≈ {mio(e['hinweis_token'])} Token), "
              f"gezielt in Grenzen {de(e['in_grenzen'], 0)} von {de(e['gezielt_geliefert'], 0)}")
    if e["karte"]:
        print(f"  Karte half: {de(e['gezielt_nach_karte'], 0)}x gezielt gelesen nach Karte, {de(e['ganz_trotz_karte'], 0)}x trotzdem ganz")
    if e["potenzial"]:
        print(f"  Potenzial: ganz Gelesenes haette als Gliederung ≈ {mio(e['potenzial'])} Token weniger gekostet")
    print()
    print("Zeile fuer die Lehren-Tabelle:")
    print(f"| {a.name} | {de(summe)} $ | {de(lo)}-{de(hi)} $ | {de((lo - summe) * KURS_EUR)}-"
          f"{de((hi - summe) * KURS_EUR)} € | <Nacharbeit/Verstoss> | <Lehre -> Massnahme> |")

if __name__ == "__main__":
    main()
