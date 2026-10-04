#!/usr/bin/env python3
"""Token und Kosten eines DeepSeek-Arbeitsblocks auf allen drei Ebenen.

  python3 ds/tokens.py <name> [--sitzung <id>] [--seit <ISO-Zeit>] [--json]

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
import argparse, glob, json, os, re, sys

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
                                                         "<local-command", "<command-name>"))
               for t in texte)

def steuerung(pfad, name, namen):
    """Opus-Aufrufe, deren Tool-Eingaben <name> nennen, anteilig je genannter
    Auftraege, und die Vorbereitung davor (s. Kopf).
    Rueckgabe: (Steuerung je Modell, Vorbereitung je Modell, ctx des ersten Aufrufs)."""
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
    je, vor, ctx = {}, {}, None
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
    return je, vor, ctx or 0

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

def main():
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
        opus, ctx = transkript(haupt, a.seit), 0
    else:
        opus, vor, ctx = steuerung(haupt, a.name, namen)
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
    if a.json:
        je = {}
        for ebene, modell, s in zeilen:
            je[ebene.split(" (")[0]] = je.get(ebene.split(" (")[0], 0) + (kosten(s, modell) or 0)
        je["DeepSeek"] = kosten(ds, ds_modell) or 0
        gesamt = sum(je.values())
        print(json.dumps({"name": a.name, "zuege": zuege, "laeufe": n, "ctx": ctx, "kosten": je,
                          "delegation": gesamt, "direkt": [direkt(ds, ctx, 0.35), direkt(ds, ctx, 0.70)]}))
        return
    print(f"Token und Kosten: {a.name}")
    print()
    print("| Ebene | Modell | Aufrufe | Eingabe | Cache gelesen | Cache geschrieben | Ausgabe | Kosten |")
    print("|---|---|---:|---:|---:|---:|---:|---:|")
    summe = 0.0
    for ebene, modell, s in zeilen + [(f"DeepSeek ({n} {'Lauf' if n == 1 else 'Läufe'}, {zuege} Züge)", ds_modell, ds)]:
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
          f"Faktor {de(lo / summe, 1)}-{de(hi / summe, 1)}x")
    print()
    print("Zeile fuer die Lehren-Tabelle:")
    print(f"| {a.name} | {de(summe)} $ | {de(lo)}-{de(hi)} $ | {de((lo - summe) * KURS_EUR)}-"
          f"{de((hi - summe) * KURS_EUR)} € | <Nacharbeit/Verstoss> | <Lehre -> Massnahme> |")

if __name__ == "__main__":
    main()
