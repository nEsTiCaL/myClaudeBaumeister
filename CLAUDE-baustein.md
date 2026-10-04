## Delegation an DeepSeek -> Schlagwoerter "Bauleiter:" und "Bauleiter-Plan:"

Beginnt eine Aufgabe mit `Bauleiter:` oder `Bauleiter-Plan:`, geht sie ueber
den Subagenten `ds-bauleiter` (Haiku 4.5) an DeepSeek. Opus (du) behaelt
Design, Review, Uebernahme und Commits; DeepSeek erkundet und baut im eigenen
Worktree. Fehlen noch Designentscheidungen: erst mit dem Nutzer klaeren --
Haiku und DeepSeek entscheiden nichts.

Welcher Weg (Messung 38 Laeufe, ds/LEHREN.md): Delegation kostet ~0,3-1 $
Grundbetrag (Median 1 $, davon 80 % Opus), Opus direkt ~0,035 $ je
DeepSeek-Zug; DeepSeek braucht etwa 2-3x so viele Zuege wie du selbst.
- Wuerdest du es in <= ~15 Werkzeugzuegen selbst bauen: direkt, ohne Bauleiter.
- Du kennst die Stellen schon (im Kontext): `Bauleiter:` (klassisch).
- Du muesstest den Code erst erkunden, die Sitzung ist frisch, oder es wird
  gross (> ~100 Zuege): `Bauleiter-Plan:` -- DeepSeek erkundet und plant.
- Sehr gross / mehrsprachiger Vertrag: `Bauleiter-Plan:`, im Plan schneiden lassen.

### `Bauleiter:` (klassisch)
Auftrag (aus deinem vorhandenen Kontext, nichts neu lesen): schreibe ihn
selbst als `ds/arbeit/<name>.auftrag.md` nach `ds/auftrag-vorlage.md`
(Name a-z0-9-). Der Bauleiter aendert ihn nicht; du rufst ihn nur mit
`Name: <name>` auf (`ds/tokens.py` sucht genau diese Zeile).
Nur hinein, was DeepSeek nicht selbst findet: Entscheidungen, Zahlen,
Formeln, Reihenfolgen, Grenzen, Einstiegsstellen `datei:zeile`.
- "Alle Leser": bei geaenderter Signatur/Codec/Raster/Flag-Bedeutung jede
  Fundstelle (grep), auch Tests, Tools, andere Sprachen.
- "Randfaelle": Wiederhol-, Grenz-, Leerfall je als Testfall; "Verhalten
  unveraendert" nennt den Test, der es festnagelt.
- Abnahmebefehle als ```sh-Block, je Zeile ein Befehl aus der Repo-Wurzel,
  ohne laufende Server.
- Paketgroesse: Ziel <= ~150 Worker-Zuege; grosse, mehrsprachige Umbauten
  in Vertrag -> Teil A || Teil B schneiden.

### `Bauleiter-Plan:` (DeepSeek plant, du pruefst ohne Code)
1. Kurzauftrag `ds/arbeit/<name>.auftrag.md` nach `ds/plan-vorlage.md`:
   Ziel, Leitplanken (alle Entscheidungen), Nicht anfassen, Abnahme. Keinen
   Code lesen -- Fundstellen sucht DeepSeek.
2. Bauleiter mit `Name: <name>` und `Phase: plan`. Er meldet Formpruefung,
   offene Fragen und Schnitt.
3. `ds/arbeit/<name>.plan.md` selbst lesen (nicht zusammenfassen lassen).
   Pruefe: Entscheidungen (jede bestaetigen oder korrigieren), offene Fragen,
   Vollstaendigkeit "Alle Leser" (bei Zweifel den genannten grep selbst
   laufen lassen), Randfaelle mit Test, Schnitt (hoechstens 4 Pakete).
4. Freigabe `ds/arbeit/<name>.freigabe.md` -- nur Abweichungen, z. B.:
   ```
   - Entscheidung 2: NEIN -- stattdessen ... (Grund)
   - Frage 1: Antwort
   - Schnitt: ein Paket          (nur wenn der Plan mehrere hat, du aber eins willst)
   Alles andere: freigegeben.
   ```
   Schnitt aendern: direkt im Abschnitt `## Schnitt` der plan.md, dann
   `ds/ds-worker.sh form <name>`.
5. Ein Paket: Bauleiter mit `Name: <name>` und `Phase: bauen`.
   Mehrere Pakete: `ds/ds-worker.sh teilen <name>` erzeugt `<name>-p1` ...
   (je Paket ein Auftrag, NICHT anfassen = Dateien der anderen). Pakete ohne
   `nach:` parallel per Bauleiter `Name: <name>-pN` (ohne Phase); ein Paket mit
   `nach: P1` erst, wenn P1 uebernommen ist. Zum Schluss
   `ds/ds-worker.sh pruefen <name> --haupt` (Gesamtabnahme).

### Nach dem Bericht (beide Wege)
1. Offene Fragen an den Nutzer.
2. Heikle Stellen gegenlesen: `ds/ds-worker.sh diff <name> -- <datei>`.
3. `ds/ds-worker.sh uebernehmen <name>` (prueft danach selbst im Haupt-Checkout).
4. Erkenntnisse ins Projektgedaechtnis, Commit vorschlagen (nicht ungefragt committen).
5. Dem Nutzer `ds/ds-worker.sh tokens <name>` zeigen; Hauptzahl ist die Ersparnis.
6. Lernschleife: Zeile + Massnahme in `ds/LEHREN.md`.

Parallele Laeufe gehen, wenn die Auftraege nach Dateien schneiden. Vorher
Zwischenstand committen, Uebernommenes sofort committen.

Ersatz, falls `ds-bauleiter` noch nicht geladen ist (erst nach Neustart):
Subagent `general-purpose` mit model=haiku, Prompt "Lies
.claude/agents/ds-bauleiter.md und befolge es" + `Name: <name>`. Achtung: dann greift
der Sperr-Hook aus dem Frontmatter NICHT.
