#!/usr/bin/env python3
"""Plan-Modus: Formpruefung und Schnitt eines DeepSeek-Plans.

  python3 ds/plan.py pruefen <name>  # ds/arbeit/<name>.plan.md: Abschnitte, Belege, Schnitt
  python3 ds/plan.py pakete  <name>  # Zahl der Pakete im Schnitt
  python3 ds/plan.py teilen  <name>  # je Paket ds/arbeit/<name>-pN.auftrag.md

Die Form prueft das Skript, den Inhalt Opus (ohne Code zu lesen). teilen
schreibt die Paket-Auftraege mechanisch -- kein Modell formuliert um (beim
Umschreiben gingen frueher Entscheidungen verloren). NICHT anfassen eines
Pakets = Dateien aller anderen Pakete. Aufgerufen ueber ds/ds-worker.sh
(plan, form, bauen, teilen); DS_WT_BASIS = Ordner der Worktrees, DS_PAKETE =
Hoechstzahl Pakete.
"""
import glob, os, re, sys

ABSCHNITTE = ["Befunde", "Alle Leser", "Entscheidungen", "Offene Fragen", "Randfaelle", "Schnitt"]
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARBEIT = os.path.join(REPO, "ds", "arbeit")
PAKETE_MAX = int(os.environ.get("DS_PAKETE", "4"))
PAKET = re.compile(r"^-\s*(P\d+)\s+([^|]*?)\s*\|\s*Aendern:\s*([^|]*?)\s*\|\s*nach:\s*(.*?)\s*$")
ABNAHME = re.compile(r"^\s+Abnahme:\s*(.+?)\s*$")


def lies(pfad):
    with open(pfad, encoding="utf-8") as f:
        return f.read()


def abschnitte(text):
    """{Titel: Inhalt} je '## '-Abschnitt (Titel ohne Klammerzusatz)."""
    teile, titel = {}, None
    for zeile in text.splitlines():
        if zeile.startswith("## "):
            titel = re.sub(r"\s*\(.*\)$", "", zeile[3:]).strip()
            teile[titel] = []
        elif titel:
            teile[titel].append(zeile)
    return {k: "\n".join(v).strip() for k, v in teile.items()}


def dateien(liste):
    return [d.strip().strip("`").strip() for d in liste.split(",") if d.strip().strip("`").strip()]


def befehle(text):
    """Abnahme-Zeile: `a`, `b` oder ein einzelner Befehl."""
    stuecke = re.findall(r"`([^`]+)`", text)
    return stuecke if stuecke else [text.strip()]


def pakete(schnitt):
    liste = []
    for zeile in schnitt.splitlines():
        m = PAKET.match(zeile)
        if m:
            nach = [] if m.group(4).strip() in ("-", "") else re.findall(r"P\d+", m.group(4))
            liste.append({"id": m.group(1), "kurz": m.group(2).strip("` "), "aendern": dateien(m.group(3)),
                          "nach": nach, "abnahme": []})
            continue
        m = ABNAHME.match(zeile)
        if m and liste:
            liste[-1]["abnahme"] += befehle(m.group(1))
    return liste


def aendern_laufender(name):
    """Dateien aus "Aendern" anderer Auftraege, deren Worktree gerade existiert."""
    basis, laufend = os.environ.get("DS_WT_BASIS", ""), {}
    for pfad in glob.glob(os.path.join(ARBEIT, "*.auftrag.md")):
        n = os.path.basename(pfad)[: -len(".auftrag.md")]
        if n == name or n.startswith(name + "-p") or not os.path.isdir(os.path.join(basis, n)):
            continue
        for zeile in lies(pfad).splitlines():
            m = re.match(r"^-\s*Aendern:\s*(.+)$", zeile)
            if m:
                laufend[n] = set(dateien(m.group(1)))
    return laufend


def zyklus(liste):
    nach = {p["id"]: p["nach"] for p in liste}
    def tief(k, weg):
        if k in weg:
            return True
        return any(tief(n, weg | {k}) for n in nach.get(k, []))
    return any(tief(k, set()) for k in nach)


def pruefen(name):
    text = lies(os.path.join(ARBEIT, name + ".plan.md"))
    teile = abschnitte(text)
    fehler, warnungen = [], []
    for a in ABSCHNITTE:
        if a not in teile:
            fehler.append(f"Abschnitt '## {a}' fehlt")
    befunde = re.findall(r"[\w./-]+\.\w+:\d+", teile.get("Befunde", ""))
    if "Befunde" in teile and not befunde:
        fehler.append("Befunde ohne Beleg datei:zeile")
    liste = pakete(teile.get("Schnitt", ""))
    if "Schnitt" in teile and not liste:
        fehler.append("Schnitt ohne Paketzeile '- P1 <kurz> | Aendern: ... | nach: -'")
    if len(liste) > PAKETE_MAX:
        fehler.append(f"Schnitt zu fein: {len(liste)} Pakete, hoechstens {PAKETE_MAX}")
    besitzer = {}
    for p in liste:
        if not p["aendern"]:
            fehler.append(f"{p['id']} ohne Dateien")
        if not p["abnahme"]:
            fehler.append(f"{p['id']} ohne Abnahme-Zeile")
        for n in p["nach"]:
            if n not in {q["id"] for q in liste}:
                fehler.append(f"{p['id']} nach unbekanntem {n}")
        for d in p["aendern"]:
            if d in besitzer:
                fehler.append(f"{d} in {besitzer[d]} und {p['id']} (Dateien muessen disjunkt sein)")
            besitzer.setdefault(d, p["id"])
    if zyklus(liste):
        fehler.append("Schnitt hat einen Abhaengigkeitskreis")
    for n, menge in aendern_laufender(name).items():
        gemeinsam = sorted(menge & set(besitzer))
        if gemeinsam:
            warnungen.append(f"kollidiert mit laufendem Auftrag {n}: {', '.join(gemeinsam)}")

    fragen = [z for z in teile.get("Offene Fragen", "").splitlines()
              if z.strip().startswith("-") and not re.match(r"^-\s*\(?keine\)?\.?\s*$", z.strip(), re.I)]
    entscheidungen = [z for z in teile.get("Entscheidungen", "").splitlines() if z.strip().startswith("-")]
    print("Form: " + ("ok" if not fehler else f"FEHLER ({len(fehler)})"))
    for f in fehler:
        print("- FEHLER " + f)
    for w in warnungen:
        print("- WARNUNG " + w)
    print(f"Befunde: {len(befunde)} Belege, Entscheidungen: {len(entscheidungen)}, Offene Fragen: {len(fragen)}")
    for z in fragen[:5]:
        print("  " + z.strip())
    for p in liste:
        print(f"Schnitt {p['id']} {p['kurz']}: {len(p['aendern'])} Dateien, nach: {', '.join(p['nach']) or '-'}")
    return 1 if fehler else 0


def teilen(name):
    auftrag = lies(os.path.join(ARBEIT, name + ".auftrag.md"))
    plan = lies(os.path.join(ARBEIT, name + ".plan.md"))
    frei = lies(os.path.join(ARBEIT, name + ".freigabe.md"))
    liste = pakete(abschnitte(plan).get("Schnitt", ""))
    if len(liste) < 2:
        sys.exit("Schnitt hat nur ein Paket -- ds-worker.sh bauen statt teilen")
    if pruefen(name):
        sys.exit("Plan-Form fehlerhaft -- Schnitt in plan.md korrigieren, dann erneut teilen")
    # Auftrag ohne Abnahme (die gilt fuer das Ganze, s. pruefen --haupt);
    # Plan ohne Schnitt; Ueberschriften eine Ebene tiefer.
    ohne_abnahme = re.split(r"(?m)^## Abnahme\b", auftrag)[0].rstrip()
    titel = (ohne_abnahme.splitlines() or ["# Auftrag"])[0]
    rumpf = "\n".join(ohne_abnahme.splitlines()[1:]).strip()
    plan_ohne_schnitt = re.split(r"(?m)^## Schnitt\b", plan)[0].rstrip()
    tiefer = lambda t: re.sub(r"(?m)^## ", "### ", t)
    for p in liste:
        k = p["id"][1:]
        andere = sorted({d for q in liste if q is not p for d in q["aendern"]})
        nach = ", ".join(f"{name}-p{n[1:]}" for n in p["nach"]) or "-"
        text = f"""{titel} -- Paket {p['id']} {p['kurz']}
<!-- erzeugt von ds/plan.py teilen aus {name}.auftrag/.plan/.freigabe; nicht von Hand aendern -->

{rumpf}

## Paket
Du baust NUR Paket {p['id']} ({p['kurz']}) des freigegebenen Plans; die anderen
Pakete bauen eigene Laeufe. Baut auf (schon uebernommen): {nach}.

## Umfang
- Aendern: {', '.join(p['aendern'])}
- NICHT anfassen: {', '.join(andere) or '-'}

## Freigabe (Opus) -- gilt vor dem Plan
{tiefer(frei.strip())}

## Plan (freigegeben; Schnitt weggelassen)
{tiefer(plan_ohne_schnitt)}

## Abnahme
```sh
""" + "\n".join(p["abnahme"]) + "\n```\n"
        ziel = os.path.join(ARBEIT, f"{name}-p{k}.auftrag.md")
        with open(ziel, "w", encoding="utf-8") as f:
            f.write(text)
        print(f"{name}-p{k}: {os.path.relpath(ziel, REPO)} (nach: {nach})")
    print(f"Gesamtabnahme nach Uebernahme aller Pakete: ds/ds-worker.sh pruefen {name} --haupt")
    return 0


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("pruefen", "pakete", "teilen"):
        sys.exit(__doc__.split("\n\n")[1])
    befehl, name = sys.argv[1], sys.argv[2]
    if befehl == "pakete":
        print(len(pakete(abschnitte(lies(os.path.join(ARBEIT, name + ".plan.md"))).get("Schnitt", ""))))
        return 0
    return pruefen(name) if befehl == "pruefen" else teilen(name)


if __name__ == "__main__":
    sys.exit(main())
