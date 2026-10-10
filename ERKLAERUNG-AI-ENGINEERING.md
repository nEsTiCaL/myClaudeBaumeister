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
  --tools Read,Edit,Write,Glob,Grep,Bash --max-turns 250 \
  --setting-sources project,local --settings <PostToolUse-Hook> \
  --allowedTools <Read/Edit/… + Test-Präfixe aus ds/projekt.sh> \
  --disallowedTools 'Edit(memory/**)' 'Bash(git commit:*)' … WebFetch WebSearch \
  --append-system-prompt "$ROLLE"  < auftrag.md
```

Vorteil: dasselbe Agent-Harness (Tools, CLAUDE.md, Permissions) – nur das
Modell ist billig. Die Hauptsitzung und das Claude-Abo bleiben unberührt.
Alle Modell-Aliase werden umgebogen, damit kein interner Subagent versehentlich
bei Anthropic landet.

### Backend-Schalter: DeepSeek oder eigener Server (2026-10-10)
Wo DeepSeek nicht erlaubt ist (Firmennetz, regulierter Code), übernimmt ein
eigener Server mit Anthropic-Messages-API die Arbeiter-Rolle, z. B. vLLM auf
einer einzelnen RTX 5090. `DS_BACKEND=lokal` biegt dieselbe Claude-Code-Instanz
auf `DS_BASE_URL` um. Alles andere (Worktree, Abnahme, Hooks, Etappen,
Plan-Modus) bleibt gleich. Unterschiede aus dem Betrieb:

- **Modell-Prüfung:** Ein geteilter Server bekommt vom Admin andere Modelle.
  `probe` prüft `/v1/models`, bevor ein Worktree entsteht (Exit 3).
- **Prefix-Cache:** Der Attribution-Header von Claude Code ändert den
  Prompt-Anfang je Anfrage. Lokal ist er aus, sonst rechnet der Server bei
  jedem Zug den ganzen Kontext neu (gemessen: 52k Token kalt 9,7 s, mit
  Cache-Treffer 2,3 s).
- **Fenster:** Claude Code kennt das Kontextfenster eines unbekannten Modells
  nicht (`unrecognized_model`). Die Etappengrenze (`DS_KONTEXT`, lokal 80k)
  ist damit die einzige Begrenzung und liegt unter dem Server-Maximum.
- **Isolation:** eigenes `CLAUDE_CONFIG_DIR`; geerbte Claude-Variablen der
  Bauleiter-Sitzung (Anmeldung, Sitzungs-IDs, Sockets) werden entfernt.

Erster Lauf (vLLM 0.28, Qwen3.8-27B NVFP4, RTX 5090, Testprojekt textstats):
9 Züge, 59 s, Abnahme grün, Übernahme sauber. Für Aussagen über große
Aufträge fehlen noch Messungen. Zu erwarten sind mehr Züge und mehr
Nacharbeit als mit DeepSeek.

### Aufgabenliste als Datei statt TodoWrite (2026-10-10)
Claude Code 2.1.29x bietet im Headless-Modus kein `TodoWrite` mehr (statt
dessen `TaskCreate`/`TaskUpdate`/`TaskList`). `--tools …,TodoWrite` ließ das
Werkzeug still weg; Merk-Hook und Staffelstab liefen damit ins Leere. Statt
auf die neuen Namen umzustellen, ist die Liste jetzt eine Datei
`.ds/aufgaben.md` im Worktree (`- [ ] Teilschritt -- datei:zeile`, darunter
`## Notizen`). Sie

- hängt an keinem Werkzeugnamen und keinem Claude-Code-Release,
- lässt sich von jedem Modell mit Write/Edit pflegen,
- liegt nach einem Watchdog-Abbruch noch auf der Platte,
- ist per `info/exclude` aus Diff, Übernahme und Fortschrittsmessung heraus.

Der Merk-Hook zählt Write/Edit auf diese Datei als Aktualisierung
(TodoWrite/TaskCreate/TaskUpdate zählen weiter mit), der Staffelstab liest
die Datei. Im ersten Lauf legte der Arbeiter sie ungefragt mit Fundstellen an.
Bei einer erzwungenen Etappe (`DS_KONTEXT=9000`) kam sie vollständig in der
frischen Sitzung an.

### Isolation per git-Worktree
- `start` legt `../<repo>-ds/<name>` auf Zweig `ds/<name>` an.
- **Basis = Arbeitsstand, nicht HEAD:** uncommittete Änderungen und neue,
  unversionierte Dateien wandern als „ds-Basis“-Commit in den Zweig. `diff`
  und `uebernehmen` zeigen danach *nur* die Arbeit des Workers.
- `uebernehmen` wendet den Patch ohne Index an (Staging des Nutzers bleibt)
  und führt die Abnahme im Haupt-Checkout erneut aus. Passt der ganze Patch
  nicht, geht es Datei für Datei mit Bericht je Datei:
  - `ok`: sauber angewendet
  - `schon da`: Stand bereits vorhanden
  - `kopiert`: neue Datei
  - `3way`: zusammengeführt, nur diese Datei wird gestagt, weil `--3way`
    den Index braucht
  - `KONFLIKT`: Marker gesetzt oder neue Datei mit anderem Inhalt vorhanden
  - `FEHLT`

  Bleibt ein Rest, bleibt auch der Worktree stehen, und der Befehl endet mit
  Exit 1. Ein zweiter Aufruf nach der Handlösung meldet `schon da`. Vorher
  löste Opus solche Fälle jedes Mal von Hand: Konflikt bei parallelen
  Paketen, dirty Baum, `.uid` neuer Dateien.
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

### Lesebudget, Vorerkundung und Etappen ohne Fortschritt
Ein Staffelstab hilft nur, wenn die Sitzung schon etwas gebaut oder notiert
hat. Ein UI-Einbau (2026-10-05) zeigte den Fehlerfall: Etappe 1 las 21 Züge
lang ganze Dateien (allein `main.gd` mit 3300 Zeilen ≈ 57k Token), endete bei
110k ohne Edit, ohne Aufgabenliste und ohne Notiz. Etappe 2 bekam einen leeren
Staffelstab und las alles noch einmal. Nach vier Etappen waren ~365k Token
gelesen und keine Zeile gebaut. Drei Gegenmaßnahmen greifen ineinander:

- **Lesebudget vor dem Start** (`ds/plan.py budget`, `ds-worker.sh budget
  <name>`): Die Token der im Auftrag genannten Dateien werden geschätzt, als
  würden sie ganz gelesen: (Bytes + 7·Zeilen) / 2,66. Die 7 Zeichen sind die
  Zeilennummer, die Read voranstellt. Der Faktor 2,66 ist der Median aus 404
  Read-Ergebnissen echter Läufe (10–90 %: 2,2–2,9); ein Tokenizer ist dafür
  nicht nötig. Zum Kern zählen nur Dateien aus Ändern/LÖSCHEN/Lies
  zuerst/Einstiegsstellen. Ein Abgleich mit allen bisherigen Aufträgen
  zeigte: Die Summe aller nur erwähnten Dateien sagt nichts voraus. Fast
  jeder Auftrag liegt über 55k, und Arbeiter lesen davon meist nur Teile. Der
  Kern trennt dagegen gut: Alle Läufe seit Einführung der Etappen mit Kern
  ≥ 55k hatten Etappen, darunter nur einzelne.
- **Vorerkundung** (Planer im Baumodus): Liegt der Kern über
  `DS_LESEBUDGET` (Standard `DS_KONTEXT`/2), erkundet zuerst eine
  Nur-Lese-Sitzung mit Planer-Werkzeugen und schreibt eine **Lagekarte**:
  Fundstellen `datei:von-bis`, Schnittstellen (Signaturen, damit fremde
  Dateien nicht gelesen werden müssen), Alle Leser, Reihenfolge, Lücken.
  Anders als im Plan-Modus trifft sie keine Entscheidungen, die stehen
  schon im klassischen Auftrag. Darum muss Opus nichts freigeben. Gebaut
  wird mit Auftrag + Lagekarte in einer frischen Sitzung, die nur noch die
  Fundstellen liest. Die Lagekarte ist Teil des Grund-Prompts und damit
  auch jedes Staffelstabs.
- **Etappe ohne Fortschritt**: Ändert sich der Worktree-Diff in einer
  Etappe nicht, startet keine gleiche Etappe mehr. Beim ersten Mal folgt
  eine Vorerkundung, falls es noch keine gab, sonst endet der Lauf mit
  **Exit 6 (zu groß)**. Die Etappengrenze endet ebenfalls mit Exit 6; bis
  2026-10-05 meldete sie Exit 0. Der Bauleiter macht bei 6 keine
  Nacharbeit, Opus teilt oder wechselt in den Plan-Modus.
  Offener Grenzfall (2026-10-10, erzwungene Etappe bei `DS_KONTEXT=9000`):
  War die Arbeit am Ende von Etappe 1 schon fertig, ändert Etappe 2 nichts
  mehr und der Lauf endet mit Exit 6, obwohl die Abnahme grün ist. Mögliche
  Maßnahme: vor Exit 6 `pruefen` laufen lassen, grün = erledigt.
- **Merk-Hook** (`ds/arbeiter-merker.sh`, PostToolUse auf Read/Grep/Glob):
  Nach 12 Lese-Schritten ohne Aufgabenliste und ab 60 % der Etappengrenze
  hängt er eine Erinnerung an das Werkzeug-Ergebnis. Der Arbeiter soll
  dann die Aufgabenliste mit Fundstellen per TodoWrite anlegen oder
  aktualisieren, also seinen Staffelstab. Die Regel stand vorher nur im
  Rollen-Prompt und wurde ignoriert (Prompt → Hook). Nachgespielt am
  Transkript des UI-Einbaus hätte er bei 49k Kontext angeschlagen.

Nebenbefund: Die Ersatz-Ergebnisse von Etappen und Watchdog-Abbrüchen
zählten **0 Ausgabe-Token**. Im Stream tragen die assistant-Nachrichten
`output_tokens: 0`, die echte Zahl steht nur in den `message_delta`-
Ereignissen, und die wurden vorher herausgefiltert. Seit 2026-10-05 bleiben
sie im Protokoll und werden summiert. Ältere Messungen mit Etappen
unterschätzen Ausgabe und Direkt-Schätzung, die Ersparnis ist dort also
eher zu niedrig.

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
| Liest Dateien ganz, keine Aufgabenliste → leerer Staffelstab bei der Etappe | **PostToolUse-Hook** `ds/arbeiter-merker.sh` auf Read/Grep/Glob: verlangt TodoWrite mit Fundstellen (nach 12 Lese-Schritten, ab 60 % der Etappengrenze) |
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

### Karte: Struktur aus dem Syntaxbaum statt Lesen (`ds/karte`)
Die Vorbereitung durch Opus (Fundstellen, „Alle Leser“) war mit 37 % der
größte Kostenblock der Delegation. Den größten Teil davon kann ein Syntaxbaum
beantworten, ohne dass ein Modell Code liest. `ds/karte` ist ein Go-Binary
mit tree-sitter. Die Abfragen sind `.scm`-Queries, übernommen aus dem
Stratum-Indexer und an die offiziellen Grammatiken angepasst. Es kennt Go,
GDScript und Python. Ein Lauf über ~130 Dateien dauert 0,4 s. Opus stellt
damit drei Fragen:

| Frage | Befehl | Ersetzt |
|---|---|---|
| Was gibt es wo? | `dateien`, `gliederung` | Dateien öffnen, um sich zu orientieren |
| Wo genau? | `symbol` | `datei:zeile` per Read suchen |
| Wer hängt davon ab? | `leser` | grep + Read jeder Fundstelle |

Beispiel: Eine Datei mit 3371 Zeilen (≈ 57k Token) hat eine Gliederung von 159
Zeilen (≈ 3k Token).

**Güte ist ausgewiesen.** Definitionen, Zeilenbereiche und aufgelöste Importe
sind exakt. Bei `leser` ordnet die Karte jeden Treffer seiner Definition nach
den Regeln der Sprache zu. Go: Unqualifiziert geht nur im selben Paket,
qualifiziert über den aufgelösten Import-Alias. GDScript: Unqualifiziert geht
nur in der Datei selbst oder per `extends`, qualifiziert über
`const X = preload(...)`. Treffer, die zu nichts im Repo gehören (`flag.Parse`
statt `arena.Parse`), Feldzugriffe auf Werten und gleichnamige Deklarationen
blendet sie aus und zählt sie nur. Ohne Typprüfung bleibt `wert.methode()` ein
Hinweis (`?`). Einen Namen als String (`call_deferred("f")`) markiert sie als
dynamisch, Treffer in Szenen und Doku als „Andere Datei“. Die Karte ist damit
genauer als grep, aber kein Typprüfer.

Gemessen an `arena.Parse` in einem Go-Server: grep liefert 11 Aufrufe, davon
3 fremde (`flag.Parse`, `time.Parse`) und 3 eines anderen Pakets. `karte leser`
liefert die 5 richtigen und nennt die übrigen als ausgeblendet.

**Messung:** `ds/tokens.py --karte` stellt die Läufe ohne und mit Karte
gegenüber. Basis (61 Läufe ohne Karte, EnteEnteFuchs): Opus liest kaum ganze
Dateien (≈ 2k Token Code je Lauf), sucht aber 5,2-mal per grep. Teuer ist
nicht das Gelesene, sondern der Zug: 6,8 Erkundungszüge je Lauf ≈ 0,39 $,
weil jeder Zug den Sitzungskontext neu liest. Die Karte hilft, wenn diese
Zahl sinkt, also `leser`/`symbol` mehrere grep-und-sed-Runden ersetzen.
Wenn `gliederung` vor ganzem Lesen steht, ist das zweitrangig.

**Von selbst statt gelernt (Hook `karte-hinweis.sh`):** In den ersten vier
Läufen mit installierter Karte hat Opus sie kein einziges Mal aufgerufen: Es
erkundet, bevor es an Delegation denkt, und neue Werkzeuge muss jede Sitzung
neu entdecken. Deshalb kommt die Karte jetzt zu Opus. Ein PostToolUse-Hook
erkennt nach jedem grep/sed/Read die berührten Code-Dateien und gesuchten
Namen. Er hängt im selben Zug an, was grep nicht liefert:
- die Funktionsgrenzen jeder neu berührten Datei (`karte index`),
- zu gesuchten Namen Definition und Verwendungen, gruppiert nach umschließender
  Funktion mit Bereich (`karte verwendung`).

So wird der nächste `sed -n` gezielt, statt einen Bereich zu raten, und das
grep nach der Definition entfällt. Je Sitzung liefert der Hook jede Datei nur
einmal und nach einer Änderung neu. Simuliert an 65 Sitzungen: ~4k Token je
Sitzung, und bei 47 % der Lesezugriffe lag die Gliederung schon vor. Ob das
Erkundungszüge spart, zeigt `ds/tokens.py --karte` (Spalten Hinweise und
„in Grenzen“).

**Grammatiken:** Go und Python kommen als Go-Module von tree-sitter. Das
GDScript-Modul ist upstream nicht nutzbar, weil sein Modulpfad falsch ist. Die
C-Quellen liegen deshalb unter `karte/grammatik/gdscript/` (Herkunft, Stand,
`aktualisieren.sh`). Neue Sprachen brauchen eine Grammatik, `symbole.scm` und
`importe.scm` sowie einen Eintrag in `karte/sprache.go`.

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
- Braucht GNU-Werkzeuge (`stat -c`, `tac`, `cp --reflink`) und bash ≥ 4.4:
  Linux oder Git-Bash unter Windows (`pgrep` ist seit 2026-10-10 nicht mehr nötig).
- **Lokales Backend:** schwächere Modelle als DeepSeek (32-GB-Klasse), daher
  kleinere Pakete und eher der klassische Weg als der Plan-Modus. Ein geteilter
  Server bremst parallele Nutzer gegenseitig aus (KV-Cache); Pakete nacheinander.
- Ersparnis basiert auf einem Schätzmodell; für belastbare Aussagen einzelne
  Aufträge kontrolliert doppelt bauen.

## 9. Dateien

Im Modul liegt alles unter `vorlage/`; `installieren.sh` kopiert es ins
Projekt (Einrichtung: README.md).

| Datei im Projekt | Zweck |
|---|---|
| `.claude/agents/ds-bauleiter.md` | Subagent: Rolle, Ablauf, Berichtsformat, Hook-Bindung |
| `ds/ds-worker.sh` | start/budget/plan/form/bauen/teilen/nacharbeit/warte/pruefen/diff/uebernehmen/verwerfen/tokens; Watchdog, Etappen, Vorerkundung |
| `ds/plan.py` | Plan-Modus: Formprüfung, Paketzahl, Teilen in Paket-Aufträge; Lesebudget |
| `ds/plan-vorlage.md` | Kurzauftrag im Plan-Modus (Projektdatei) |
| `ds/projekt.sh` | **einzige Projektanpassung**: Test-Freigaben, Read-only-Pfade, Kopien, Fehlermuster, `nach_edit` |
| `ds/bauleiter-sperre.sh` | PreToolUse-Hook des Bauleiters + Selbsttest |
| `ds/arbeiter-pruef.sh` | PostToolUse-Hook des Workers: Prüfung nach jedem Edit |
| `ds/arbeiter-merker.sh` | PostToolUse-Hook des Workers: Aufgabenliste (Staffelstab) einfordern + Selbsttest |
| `ds/auftrag-vorlage.md` | Struktur des Auftrags an DeepSeek |
| `ds/tokens.py` | Kosten je Ebene + Ersparnis-Schätzung |
| `ds/LEHREN.md` | Lernprotokoll |
| `ds/karte` | Struktur für Opus: Übersicht, Gliederung, Definition, Leser (Go-Binary aus `karte/`, optional) |
| `CLAUDE-baustein.md` (Modul) | Abschnitt für die Projekt-CLAUDE.md (Trigger `Bauleiter:` / `Bauleiter-Plan:`, Wegwahl, Auftrags-Regeln) |
