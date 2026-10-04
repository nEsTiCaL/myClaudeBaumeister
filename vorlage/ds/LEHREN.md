# Bauleiter: Lernschleife und Ersparnis je Lauf

Ziel: die Delegation wird mit jedem Lauf besser. Gemessen wird vor allem,
wie viel sie gegenueber "Opus baut direkt" spart.

## Schleife nach jedem Lauf (Opus)

1. `ds/ds-worker.sh tokens <name>` -> Ersparnis-Zeile (Delegation vs. direkt).
2. Was lief schief oder umstaendlich? (Nacharbeit, Regelverstoss, Rueckfrage,
   eigener Nachbau durch Opus, Umfangsfehler im Brief, Etappen.) War der Weg
   richtig gewaehlt (direkt / klassisch / Plan-Modus, Faustregel in CLAUDE.md)?
   Hohe "Opus-Vorbereitung" bei klassisch -> naechstes Mal Plan-Modus.
3. Jede Lehre bekommt GENAU EINE Massnahme am richtigen Ort:
   Verhalten Bauleiter -> `.claude/agents/ds-bauleiter.md` (Abschnitt Lehren,
   kurz halten); verbotenes Tun -> technisch in `ds/bauleiter-sperre.sh`;
   Auftrag -> `ds/auftrag-vorlage.md` bzw. Auftrags-Regeln in CLAUDE.md;
   Werkzeug -> `ds/ds-worker.sh`, `ds/tokens.py`.
4. Zeile in die Tabelle unten; Massnahme im selben Commit.
5. Wiederholt sich eine Lehre trotz Massnahme: Massnahme verschaerfen
   (Prompt -> Skript -> Hook), nicht nur nochmal aufschreiben.

## Laeufe

```
name (Weg)        | deleg. | direkt (Sch.) | Ersparnis      | Nacharbeit/Verstoss        | Lehre -> Massnahme
-----------------+--------+---------------+----------------+----------------------------+------------------------------
```
