# Bauleiter: Drei-Ebenen-Delegation für Claude Code mit DeepSeek als Worker

Ein Muster, um klar umrissene Programmieraufgaben aus einer teuren
Opus-Sitzung an ein günstiges Modell auszulagern, ohne Kontrolle über
Design, Review und Repo-Zustand abzugeben. Entstanden und gemessen in einem
Go/Godot-Spieleprojekt (Okt. 2026), hier als projektneutrale Vorlage.

## 1. Problem

In einer langen Claude-Code-Sitzung ist nicht die Ausgabe der Kostentreiber,
sondern **Cache-Read des Sitzungskontexts je Zug**. Bei ~100–160k Kontext
kostet jeder Opus-Zug einige Cent, bevor eine Zeile Code entsteht. Eine
Implementierung mit 30–80 Werkzeugzügen (grep, Read, Edit, Test) vervielfacht
das. Diese Züge brauchen aber kaum Urteilskraft – sie brauchen einen frischen,
kleinen Kontext und ein brauchbares Codemodell.

## 2. Architektur

```
┌────────────────────────────┐   Auftrag-Datei ds/arbeit/<name>…   ┌───────────────────────────┐
│ Opus  (Hauptsitzung)       │   Aufruf: "Name: <name>"            │ Haiku 4.5  "ds-bauleiter"  │
│ Design, Auftrag, Review,   │ ──────────────────────────────────▶ │ Subagent, kein Code-Lesen │
│ Übernahme, Gedächtnis,     │ ◀────────────────────────────────── │ start → warte             │
│ Commit-Vorschlag           │   Bericht ≤30 Zeilen + Token-Tabelle│ → pruefen → ≤2 Nacharbeit │
└────────────────────────────┘                                     └─────────────┬─────────────┘
                                                                                 │ ds/ds-worker.sh
                                                                   ┌─────────────▼─────────────┐
                                                                   │ DeepSeek (deepseek-flash) │
                                                                   │ = 2. Claude Code, headless│
                                                                   │ eigener git-Worktree      │
                                                                   │ erkundet, baut, testet    │
                                                                   └───────────────────────────┘
```

**Rollentrennung ist der Kern.** Jede Ebene hat genau eine Aufgabe und
liest nur, was sie dafür braucht:

| Ebene | Modell | Darf | Darf nicht |
|---|---|---|---|
| Auftraggeber | Opus | entscheiden, reviewen, übernehmen, committen | — |
| Bauleiter | Haiku 4.5 | Skript starten, warten, gruen/ROT lesen, Nacharbeit anstoßen | Auftrag schreiben/ändern, Code lesen, inhaltlich reviewen, übernehmen, git schreiben |
| Worker | DeepSeek | im Worktree lesen/editieren, freigegebene Test-Befehle | commit/push/checkout, Doku/Gedächtnis schreiben, Web |

## 3. Technik

### Worker = Claude Code mit anderem Backend
DeepSeek bietet einen Anthropic-kompatiblen Endpunkt. `ds/ds-worker.sh`
startet eine zweite Claude-Code-Instanz nur für diesen Prozess umgebogen:

```sh
ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic
ANTHROPIC_AUTH_TOKEN=$DEEPSEEK_API_KEY
ANTHROPIC_MODEL / DEFAULT_{OPUS,SONNET,HAIKU}_MODEL / CLAUDE_CODE_SUBAGENT_MODEL = deepseek-flash
claude -p --output-format stream-json --permission-mode acceptEdits \
  --tools Read,Edit,Write,Glob,Grep,Bash,TodoWrite --max-turns 250 \
  --setting-sources project,local --settings <PostToolUse-Hook> \
  --allowedTools <Read/Edit/… + Test-Präfixe aus ds/projekt.sh> \
  --disallowedTools 'Edit(memory/**)' 'Bash(git commit:*)' … WebFetch WebSearch \
  --append-system-prompt "$ROLLE"  < auftrag.md
```

Vorteil: dasselbe Agent-Harness (Tools, CLAUDE.md, Permissions) – nur das
Modell ist billig. Die Hauptsitzung und das Claude-Abo bleiben unberührt.
Alle Modell-Aliase werden umgebogen, damit kein interner Subagent versehentlich
bei Anthropic landet.

### Isolation per git-Worktree
- `start` legt `../<repo>-ds/<name>` auf Zweig `ds/<name>` an.
- **Basis = Arbeitsstand, nicht HEAD:** uncommittete Änderungen und neue,
  unversionierte Dateien wandern als „ds-Basis“-Commit in den Zweig. `diff`
  und `uebernehmen` zeigen danach *nur* die Arbeit des Workers.
- `uebernehmen` wendet den Patch ohne Index an (Staging des Nutzers bleibt),
  fällt nur bei Konflikt auf `--3way` zurück und führt die Abnahme im
  Haupt-Checkout erneut aus.
- Parallele Läufe funktionieren, wenn die Aufträge nach Dateien schneiden.

### Abnahme als Daten, nicht als Meinung
Der Auftrag enthält unter `## Abnahme` einen ```sh-Block. `pruefen` führt
jede Zeile aus und meldet nur `gruen`/`ROT` (+ 8 Fehlerzeilen). Optional
machen Ausgabemuster (`DS_FEHLERMUSTER`) einen Exit-0-Befehl rot – nötig bei
Engines, die Skriptfehler loggen, aber 0 zurückgeben. Der Bauleiter glaubt
dem Worker-Bericht nicht, er führt das Skript aus.

### Robustheit gegen hängende Provider
Beobachtet: `deepseek-flash` schickte minutenlang nur SSE-Keep-alives; kein
Client-Timeout griff. Gegenmaßnahmen:
- **Vorabprobe** (curl, Streaming): erstes `content_block_delta` binnen 45 s,
  sonst Exit 3 *bevor* ein Worktree entsteht.
- **Watchdog** auf die mtime des Stream-Logs (`--include-partial-messages`
  liefert jedes Token als Lebenszeichen): 90 s Stille beim API-Warten, 300 s
  während ein Tool läuft (erkannt am letzten Nicht-Stream-Event), 3600 s gesamt.
- Danach werden Token-Deltas aus dem Log entfernt (sonst ~30 MB/Lauf).
- Exit 3 ⇒ Bauleiter **wiederholt nicht** und wechselt nicht das Modell.
- Beendet das Skript `claude` selbst, gilt sein Grund, nicht das
  `error_during_execution`, das `claude` beim Beenden noch schreibt; die Token
  des abgebrochenen Laufs summiert das Skript aus dem Protokoll.
- Fallstrick `set -o pipefail`: `tac log | grep -m1 …` meldet bei großen
  Protokollen „falsch“, weil `tac` ein SIGPIPE bekommt. Bis 2026-10-04 griff
  deshalb die 300-s-Frist für laufende Werkzeuge praktisch nie (es galten
  90 s). Seither wird die Ausgabe ausgewertet, nicht der Exit-Status.

### Etappen statt Compaction
Claude Code fasst den Kontext bei ~150k automatisch zusammen. Im Test des
Plan-Modus (tempo-v7, 315 Züge) geschah das zweimal, und eine
Zusammenfassung kann genau die Korrekturen verlieren, die Opus in der
Freigabe gemacht hat. Der Watchdog misst deshalb die Kontextgröße jeder
Antwort. Über `DS_KONTEXT` (110k) beendet er die Sitzung **zwischen zwei
Zügen** (letztes Ereignis ist ein Werkzeug-Ergebnis oder „requesting“, alle
Edits sind abgeschlossen) und startet eine frische Sitzung mit einem
**Staffelstab**: Auftrag, Plan und Freigabe im vollen Wortlaut, dazu
`git diff --stat`, die letzte TodoWrite-Liste und die letzten Notizen.
Entscheidungen werden so nie zusammengefasst, nur der Arbeitsstand.
`nacharbeit` setzt eine kleine Sitzung fort (`--resume`), eine große oder
per Etappe beendete startet frisch mit Staffelstab. Bei DeepSeek ist großer
Kontext billig (Cache-Lesen 0,003 $/Mio.); es geht um Verlässlichkeit, nicht
um Kosten.

### Async ohne Polling-Kosten
Der Bauleiter startet `start` im Hintergrund und ruft `warte` (blockiert bis
570 s, unter dem 10-min-Bash-Limit) auf. Ein früherer Bauleiter nutzte
`sleep 540` – dabei verfiel sein 5-min-Prompt-Cache, und jeder Folgeaufruf
schrieb den Cache neu.

### Leitplanken: Prompt → Skript → Hook
Haiku als Bauleiter hat in der Praxis zweimal eigenmächtig übernommen und
einmal committet – dabei elf fremde Dateien paralleler Aufträge im
Haupt-Checkout zurückgesetzt (gerettet aus dem Stream-Log). Konsequenz: was
der Prompt verbietet, sperrt ein **PreToolUse-Hook im Agent-Frontmatter**
(`ds/bauleiter-sperre.sh`) technisch: `uebernehmen|verwerfen`,
git-Schreibbefehle, `rm|mv`, Write/Edit außer `ds/arbeit/<name>.nacharbeit.md`
(den Auftrag schreibt nur Opus). Exit 2 +
Begründung auf stderr, die der Agent sieht. Selbsttest: `--test`.
Regel daraus: *Wiederholt sich ein Fehler trotz Prompt-Regel, eskaliert die
Maßnahme eine Stufe (Prompt → Skript → Hook).*

### Zugzahl des Workers senken
Auswertung von 14 Läufen (~1.900 Züge, 50–315 je Auftrag): keine
Leerlauf-Schleifen, aber vermeidbare Züge. Ursachen und Gegenmittel:

| Beobachtung | Gegenmittel |
|---|---|
| Viele kleine Edits, erster Test erst nach ~100 Zügen, dann Rot-Welle | **PostToolUse-Hook** `ds/arbeiter-pruef.sh`: prüft jede editierte Datei (`nach_edit` in `ds/projekt.sh`, z. B. `go vet`, Parse-Check) und hängt Fehler als `additionalContext` an dasselbe Tool-Ergebnis |
| 4–12 abgelehnte Bash-Befehle je Lauf, je 1–5 Umformulierungen (`&&`, `cd`, Python) | Rollen-Prompt nennt die Freigaben und verbietet Umformulieren |
| `cd`-Irrwege, absolute Pfade | Rollen-Prompt: cwd = Worktree-Wurzel, relative Pfade |
| nur 15–41 % Antworten mit mehreren Tool-Aufrufen | Rollen-Prompt: unabhängige Such-/Leseschritte bündeln |
| Startkontext 21k je Zug (Schemata aller Tools, Nutzer-Settings) | `--tools` + `--setting-sources project,local` → 6,4k |
| Ausreißer (315 Züge, Kontext 167k) | Richtwert im Prompt, `--max-turns` als Notbremse, große Pakete schneiden |

`start` verweigert außerdem Aufträge mit unausgefüllten Vorlagenzeilen oder
ohne Abnahmeblock. `DS_EFFORT` setzt `--effort` für A/B-Messungen.

### Plan-Modus: DeepSeek erkundet, Opus prüft ohne Code
Beim klassischen Weg muss Opus vor dem Auftrag selbst Code lesen
(`datei:zeile`, „Alle Leser“). Diese **Vorbereitung** kostete in 38 Läufen
im Median 0,35 $ und machte 37 % aller Delegationskosten aus, mehr als
DeepSeek und Haiku zusammen. Der Plan-Modus verlagert sie:

```
Opus      Kurzauftrag (Ziel, Leitplanken, Abnahme; kein Code)   ds/plan-vorlage.md
DeepSeek  plan: nur Read/Grep/Glob, Plan als letzte Antwort      <name>.plan.md
Skript    Formprüfung (Abschnitte, Belege datei:zeile, Schnitt)  ds/plan.py
Opus      liest den Plan selbst, schreibt nur Abweichungen       <name>.freigabe.md
DeepSeek  bauen: FRISCHE Sitzung, Auftrag + Plan + Freigabe      wie start
  oder    teilen: je Paket ein Auftrag, NICHT anfassen = andere Pakete
```

Feste Gliederung des Plans: Befunde (`datei:zeile`), Alle Leser (mit
grep-Befehl als Beleg), Entscheidungen („X, weil Y“), Offene Fragen,
Randfälle (mit Test), Schnitt (≤ 4 Pakete, disjunkte Dateien, `nach:`).
Den Plan liest Opus direkt; Haiku fasst ihn nicht zusammen, und das Teilen
macht ein Skript, kein Modell.

Gemessen (Rückspiel tempo-v7, Stand vor dem Original-Commit, 2026-10-04):

| | Original (klassisch) | Plan-Modus |
|---|---:|---:|
| DeepSeek-Züge | 315 | 79 Plan + 312 Bau |
| DeepSeek-Kosten | 0,19 $ | 0,05 + 0,22 $ |
| Plan: tatsächlich geänderte Dateien gefunden | – | 27 von 28 |
| Abnahme | grün | grün |

- Der Plan war inhaltlich stark. Eine Designentscheidung wich vom gewollten
  Design ab, stand aber offen unter „Entscheidungen“ und war mit einer Zeile
  in der Freigabe korrigiert. Im Code kam die Korrektur an.
- Schwach: Der Schnitt war zu fein (9 Pakete), die Zug-Schätzungen waren
  wertlos (~52 statt 315). Darum gilt jetzt: höchstens 4 Pakete (Skript),
  und Zugzahlen schätzt der Planer nicht mehr.
- Die Bauphase setzte zuerst die Planungssitzung fort (`--resume`). Sie war
  148k groß und wurde zweimal zusammengefasst; Züge gespart hat das nicht.
  Darum startet `bauen` jetzt frisch.
- Ersparnis: Die Vorbereitung durch Opus kostete hier 0,39 $. Im Plan-Modus
  sind es geschätzt 0,10–0,15 $ für Kurzauftrag und Plan-Review, plus 0,05 $
  DeepSeek-Plan und ein zweiter Bauleiter-Start (~0,04 $), also netto etwa
  0,15–0,20 $ je Auftrag dieser Art. Das lohnt sich, wenn Opus sonst erst
  erkunden müsste (20 von 38 Läufen hatten über 0,30 $ Vorbereitung). Kennt
  Opus die Stellen schon (13 Läufe unter 0,15 $), ist der klassische Weg billiger.

## 4. Warum Haiku als Bauleiter (und nicht Sonnet oder gar keiner)

Gemessen an einem Lauf mit +996 Zeilen:
- **Sonnet-Bauleiter mit Erkundung** kostete mehr als DeepSeek *und* Opus-Steuerung:
  er las ~60k Code vor, den DeepSeek danach erneut las; ~0,53 $ allein Cache-Writes.
  Tests liefen dreifach, Review doppelt.
- **Kein Bauleiter:** Opus müsste Nacharbeit selbst steuern – genau die
  teuren Züge, die man sparen will.
- **Haiku in alter Rolle** (mit Erkundung) trifft technische Entscheidungen –
  verworfen.
- **Haiku als reine Schnittstelle** (Variante gewählt): Skripte starten,
  warten, gruen/ROT lesen, Nacharbeit steuern. Opus hat den Kontext, DeepSeek
  erkundet, niemand liest doppelt. Haiku kostet 4–8 Cent je Lauf, etwa so viel
  wie die Opus-Züge für Warten/Prüfen, die er erspart – und Opus' Fenster
  bleibt schmal, auch bei parallelen Läufen.
- **Den Auftrag schreibt Opus selbst** als Datei. Früher übertrug Haiku einen
  Brief in die Vorlage; beim Umschreiben gingen Entscheidungen verloren
  (ein Ausschlussfall fehlte danach im Auftrag). Seither sperrt der Hook das.

Hinweis: im Agent-Frontmatter die **volle Modell-ID** angeben
(`claude-haiku-4-5-20251001`); ein Alias löste einmal auf ein anderes Modell auf.

## 5. Kostenmodell und Messung

`ds/tokens.py <name>` summiert drei Ebenen aus den Transkripten:
- **Opus-Steuerung:** nur Aufrufe, deren Tool-Inputs den Auftragsnamen nennen;
  bei mehreren Namen anteilig (sonst zählen parallele Läufe doppelt).
- **Bauleiter:** Subagent-Transkripte, deren Prompt `Name: <name>` enthält.
- **DeepSeek:** `ds/arbeit/<name>.laeufe.jsonl` (ein `result`-Event je Lauf).
- Entdoppelt per `message.id`; Cache-Writes (5 min/1 h) eingepreist.

**Hauptzahl ist die Ersparnis** gegen ein kontrafaktisches „Opus baut direkt“:
35–70 % der DeepSeek-Züge, je Zug Sitzungskontext + halber neu gelesener Code
aus dem Cache, neuer Code einmal in den 1-h-Cache, Ausgabe wie DeepSeek. Das
ist eine **Schätzung**, keine Messung – die Spanne macht die Unsicherheit sichtbar.

Seit 2026-10-04 zählt `tokens.py` auch die **Opus-Vorbereitung**: alle
Aufrufe ohne Auftragsnamen von der letzten Nutzernachricht bis zum
Bauleiter-Start (Code erkunden, Auftrag denken). Vorher fehlte sie. Bei
tempo-v7 waren das 0,39 $ von 0,86 $ Opus-Anteil. `tokens.py --json` gibt
die Kennzahlen maschinenlesbar aus.

Ergebnisse aus 7 Läufen (alte Zählung ohne Vorbereitung):

| Auftrag | Delegation | Opus direkt (geschätzt) | Faktor |
|---|---:|---:|---:|
| kleines Feature | 0,46 $ | 1,33–1,89 $ | 3–4× |
| Bugfix | 0,38 $ | 1,14–1,46 $ | 3–4× |
| Input-Refactor | 0,33 $ | 2,40–3,04 $ | 7–9× |
| HUD-Umbau | 0,40 $ | 3,24–4,29 $ | 8–11× |
| Layout-Modul | 0,14 $ | 1,84–2,46 $ | 13–18× |
| Geräte-Binding | 0,16 $ | 2,29–3,06 $ | 14–19× |
| Farb-/Marker-Modul | 0,14 $ | 1,88–2,70 $ | 13–19× |

DeepSeek selbst kostet je Lauf 0,01–0,19 $. **Teuer bleibt Opus.**

### Ab wann lohnt sich der Bauleiter? (38 Läufe, neue Zählung)

| DeepSeek-Züge | Läufe | Delegation (Median) | Opus direkt (geschätzt, Median) | Ersparnis (Median) |
|---|---:|---:|---:|---:|
| unter 40 | 4 | 0,73 $ | 1,16–1,41 $ | 0,63 $, einmal Verlust |
| 40–60 | 7 | 0,84 $ | 1,66–2,16 $ | 1,18 $ |
| 60–100 | 7 | 0,60 $ | 2,35–3,06 $ | 2,11 $ |
| 100–150 | 14 | 1,14 $ | 3,84–5,23 $ | 3,33 $ |
| über 150 | 6 | 1,17 $ | 6,04–8,62 $ | 5,59 $ |

- Die Delegation hat einen **Grundbetrag** von etwa 0,3–2,8 $ (Median 1,0 $).
  82 % davon sind Opus (Vorbereitung + Steuerung), 11 % Haiku, 7 % DeepSeek.
  Die Steuerung kostet unabhängig von Opus' Kontextgröße im Median ~0,40 $.
- „Opus direkt“ kostet geschätzt ~0,03–0,04 $ je DeepSeek-Zug (mehr bei
  großem Kontext). Die Gewinnschwelle liegt damit bei **~25–30 DeepSeek-Zügen**.
  Unter ~40 Zügen ist der Gewinn klein und unsicher (Faktor 0,5–2).
- DeepSeek braucht etwa 2–3-mal so viele Züge wie Opus selbst. Faustregel:
  würde Opus es in ≤ ~15 Werkzeugzügen schaffen, baut Opus direkt.

Empfehlung:

| Lage | Weg |
|---|---|
| klein (Opus ≤ ~15 Werkzeugzüge, 1–2 Dateien) | Opus direkt |
| mittel/groß, Opus kennt die Stellen schon | `Bauleiter:` (klassisch) |
| Opus müsste erst erkunden, frische Sitzung oder > ~100 Züge | `Bauleiter-Plan:` |
| sehr groß, mehrsprachiger Vertrag | `Bauleiter-Plan:` + `teilen` |

Vorbehalt: „Opus direkt“ ist ein Modell (35–70 % der DeepSeek-Züge), keine
Messung. Die Vorbereitung enthält auch Designarbeit, die Opus beim direkten
Bauen ebenfalls hätte; die Ersparnis ist also eher unterschätzt.
Nicht erfasst: Opus-Arbeit ohne Namensnennung (Nachbesserung, Rettung).
`total_cost_usd` im Claude-Code-Result rechnet mit Anthropic-Preisen und ist
für DeepSeek falsch – deshalb das eigene Skript. Preise in `tokens.py` vor
Gebrauch prüfen.

## 6. Was einen guten Auftrag ausmacht

Empirisch aus den Läufen: Aufträge mit 400–700 Wörtern (1–2k Token) sind
nicht zu lang – der Worker trägt je Zug ~100k Kontext. Fehler entstanden
immer an zu vagen Stellen, nie an zu genauen. Deshalb zwei Pflichtfelder in
der Vorlage: **„Alle Leser“** (jede Fundstelle bei geänderter Signatur,
Codec, Raster oder Flag-Bedeutung, auch Tests/Tools/andere Sprachen) und
**„Randfälle“** (Wiederhol-, Grenz-, Leerfall je als Testfall).
- **Feste Werte im Auftrag** (Konstanten, Namen, Farben, Signaturen) → keine Rückfragen, keine Nacharbeit.
- **Reine Funktionen** mit klarer Ein-/Ausgabe sind ideal testbar.
- **„Verhalten unverändert“ braucht einen Test, der es festnagelt.** Ohne ihn
  gab es eine stille Regression, die erst Opus fand.
- **Edge-Cases explizit nennen**; das Modell findet sie nicht von selbst.
- **Nach Dateien schneiden** (`Aendern` / `NICHT anfassen`) – ermöglicht Parallelität und Umfangsprüfung per `--stat`.
- **Keine offenen Designfragen** im Auftrag. Worker und Bauleiter sollen
  anhalten und fragen, nicht entscheiden – und das funktioniert nur, wenn der Auftrag
  keine Entscheidung offenlässt.
- **Paketgröße:** Ziel ≤ ~150 Worker-Züge. Mehrsprachige Protokollwechsel in
  Vertrag → Server ‖ Client schneiden.
- Positiv beobachtet: Befunde außerhalb des Umfangs **melden statt bauen** –
  das ist erwünscht und steht so in der Worker-Rolle.

## 7. Lernschleife

Nach jedem Lauf: Token-Zeile + genau **eine** Maßnahme am richtigen Ort
(Agent-Prompt, Hook, Vorlage, Auftrags-Regel oder Skript), eingetragen in
`ds/LEHREN.md`, im selben Commit. Das hält den Bauleiter-Prompt kurz und
verschiebt harte Regeln dorthin, wo sie nicht ignoriert werden können.

## 8. Grenzen und Risiken

- **Datenabfluss:** der Worker sendet Code an DeepSeek (Drittanbieter, China).
  Für proprietären oder regulierten Code vorher klären.
- **Permissions sind Präfix-basiert.** `Bash(npm test:*)` erlaubt alles, was
  mit `npm test` beginnt. Freigaben eng halten; Worker läuft mit `acceptEdits`.
- Der Hook greift nur, wenn der Bauleiter als `ds-bauleiter` geladen ist
  (Frontmatter). Der Notbehelf „general-purpose liest die Agent-Datei“ hat
  **keine** Sperre. Agent-Hooks werden erst nach einem Neustart von Claude Code aktiv.
- Live-/Integrationstests, die Server o. ä. starten, gehören nicht in die
  Abnahme – der Worker darf sie nicht starten. Die macht Opus.
- Linux-spezifisch (`stat -c`, `tac`, `pgrep -f`, `cp --reflink`); bash ≥ 4.4.
- Ersparnis basiert auf einem Schätzmodell; für belastbare Aussagen einzelne
  Aufträge kontrolliert doppelt bauen.

## 9. Dateien

Im Modul liegt alles unter `vorlage/`; `installieren.sh` kopiert es ins
Projekt (Einrichtung: README.md).

| Datei im Projekt | Zweck |
|---|---|
| `.claude/agents/ds-bauleiter.md` | Subagent: Rolle, Ablauf, Berichtsformat, Hook-Bindung |
| `ds/ds-worker.sh` | start/plan/form/bauen/teilen/nacharbeit/warte/pruefen/diff/uebernehmen/verwerfen/tokens; Watchdog und Etappen |
| `ds/plan.py` | Plan-Modus: Formprüfung, Paketzahl, Teilen in Paket-Aufträge |
| `ds/plan-vorlage.md` | Kurzauftrag im Plan-Modus (Projektdatei) |
| `ds/projekt.sh` | **einzige Projektanpassung**: Test-Freigaben, Read-only-Pfade, Kopien, Fehlermuster, `nach_edit` |
| `ds/bauleiter-sperre.sh` | PreToolUse-Hook des Bauleiters + Selbsttest |
| `ds/arbeiter-pruef.sh` | PostToolUse-Hook des Workers: Prüfung nach jedem Edit |
| `ds/auftrag-vorlage.md` | Struktur des Auftrags an DeepSeek |
| `ds/tokens.py` | Kosten je Ebene + Ersparnis-Schätzung |
| `ds/LEHREN.md` | Lernprotokoll |
| `CLAUDE-baustein.md` (Modul) | Abschnitt für die Projekt-CLAUDE.md (Trigger `Bauleiter:` / `Bauleiter-Plan:`, Wegwahl, Auftrags-Regeln) |
