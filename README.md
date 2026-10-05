# Bauleiter – DeepSeek als günstiger Programmierer für Claude Code

Claude Opus plant, entscheidet und reviewt. DeepSeek baut in einem eigenen
git-Worktree. Ein kleiner Haiku-Subagent („Bauleiter“) startet DeepSeek,
wartet, prüft die Abnahme und meldet knapp zurück. Dadurch bleibt Opus'
Kontextfenster schmal.

Zwei Wege: **klassisch** schreibt Opus einen Auftrag mit Fundstellen.
Im **Plan-Modus** gibt Opus nur Ziel und Leitplanken vor. DeepSeek erkundet
den Code und legt einen Plan vor, den Opus ohne Code-Lesen prüft und
freigibt; danach baut DeepSeek, bei Bedarf in mehreren Paketen.

- Einfach erklärt: [LIESMICH.md](LIESMICH.md)
- Architektur, Messwerte, Begründungen: [ERKLAERUNG-AI-ENGINEERING.md](ERKLAERUNG-AI-ENGINEERING.md)

## Inhalt

```
installieren.sh          installiert/aktualisiert den Bauleiter in einem Projekt
paket.sh                 baut dist/bauleiter.tar.gz zum Weitergeben
CLAUDE-baustein.md       Abschnitt für die CLAUDE.md des Projekts (Kontext für Opus)
karte/                   ds/karte: Struktur aus dem Syntaxbaum (Go, tree-sitter), wird
                         beim Installieren gebaut; Tests: cd karte && go test ./...
vorlage/                 was ins Projekt kopiert wird:
  .claude/agents/ds-bauleiter.md   der Subagent (Haiku) inkl. Sperr-Hook
  ds/ds-worker.sh                  Werkzeug: start/budget/plan/bauen/teilen/warte/pruefen/nacharbeit/diff/uebernehmen/tokens
  ds/plan.py                       Plan-Modus: Formprüfung des Plans, Teilen in Pakete; Lesebudget
  ds/arbeiter-pruef.sh             Hook: prüft jede von DeepSeek editierte Datei sofort
  ds/arbeiter-merker.sh            Hook: verlangt DeepSeeks Aufgabenliste (Staffelstab für Etappen)
  ds/bauleiter-sperre.sh           Hook: verbietet dem Bauleiter Übernehmen, git, Auftrag ändern
  ds/tokens.py                     Kosten je Ebene + Ersparnis gegenüber „Opus baut direkt“
  ds/projekt.sh                    PROJEKTDATEI: Test-Freigaben, Prüfbefehle, Kopien
  ds/auftrag-vorlage.md            PROJEKTDATEI: Gliederung eines klassischen Auftrags
  ds/plan-vorlage.md               PROJEKTDATEI: Kurzauftrag im Plan-Modus
  ds/LEHREN.md                     PROJEKTDATEI: Lernprotokoll je Lauf
```

## Voraussetzungen

- Linux (macOS nur mit GNU coreutils und bash ≥ 4.4)
- `git`, `jq`, `curl`, `python3`, `pgrep`, [Claude Code](https://claude.com/claude-code) (`claude`)
- optional für `ds/karte`: Go ≥ 1.24 und ein C-Compiler (Grammatiken sind C). Der
  erste Build lädt die Go-Module. Ein mit `paket.sh` gebautes Archiv enthält das
  Binary schon (linux).
- DeepSeek-API-Schlüssel (platform.deepseek.com)
- das Zielprojekt ist ein git-Repository mit Tests, die per Befehl laufen

## Einrichten in einem Projekt

**1. Schlüssel ablegen** (einmal je Rechner, nie ins Projekt):
```sh
mkdir -p ~/.config/deepseek
echo 'DEEPSEEK_API_KEY=sk-...' > ~/.config/deepseek/env
chmod 600 ~/.config/deepseek/env
```

**2. Installieren:**
```sh
/pfad/zu/Bauleiter/installieren.sh /pfad/zu/projekt
```
Das Skript kopiert die Dateien aus `vorlage/`, legt `ds/arbeit/` an und trägt
es in `.gitignore` ein. Danach führt es den Selbsttest der Sperre aus und
meldet fehlende Werkzeuge oder einen fehlenden Schlüssel.

**3. `ds/projekt.sh` anpassen.** Das ist die einzige Stelle mit
Projektwissen:

| Variable/Funktion | Bedeutung | Beispiel |
|---|---|---|
| `DS_ERLAUBT` | Bash-Befehle, die DeepSeek ausführen darf (Präfixe) | `'Bash(npm test:*)'` |
| `DS_NUR_LESEN` | Verzeichnisse, die DeepSeek nur lesen darf | `(docs memory)` |
| `DS_KOPIEREN` | nicht versionierte Pfade, die Tests im Worktree brauchen | `(node_modules .env.test)` |
| `DS_FEHLERMUSTER` | Ausgabe, die einen Befehl trotz Exit 0 rot macht | `('SCRIPT ERROR')` |
| `DS_HINWEIS_PRUEFEN` | ein Satz: wie testet man gezielt? | `` 'Gezielt: `npm test -- -t <Name>`.' `` |
| `vor_pruefen()` | Vorbereitung vor jeder Abnahme | generierte Dateien kopieren |
| `nach_edit()` | schnelle Prüfung einer Datei nach jedem Edit (< 5 s), Ausgabe = Fehler | `go vet "./$(dirname "$1")/"` |

`nach_edit` ist der wichtigste Hebel gegen lange Läufe: DeepSeek sieht
Syntax- und Typfehler im selben Schritt statt nach hundert Schritten. Ob es
funktioniert, zeigt
`ds/arbeiter-pruef.sh --test <datei>` (aus der Projektwurzel).

**4. `ds/auftrag-vorlage.md` und `ds/plan-vorlage.md` anpassen:** unter
„Abnahme“ den Standard-Testbefehl eintragen (z. B. `npm test`).

**5. Opus einweisen (Kontext):** den Abschnitt aus
[CLAUDE-baustein.md](CLAUDE-baustein.md) in die `CLAUDE.md` des Projekts
übernehmen. Er enthält die Schlagwörter `Bauleiter:` und `Bauleiter-Plan:`,
die Faustregel, wann sich welcher Weg lohnt, die Regeln für den Auftrag und
die Schritte nach dem Bericht. Opus liest die `CLAUDE.md` in jeder
Sitzung, damit kennt es den Ablauf. Hat das Projekt ein eigenes Gedächtnis
oder eigene Doku: Lehren-Tabelle und Regeln dürfen dort liegen. Dann den
Verweis in der `CLAUDE.md` entsprechend setzen.

**6. Claude Code im Projekt neu starten.** Agent-Definitionen und ihre Hooks
werden nur beim Start einer Sitzung geladen.

**7. Ausprobieren:**
```
Bauleiter: Füge eine Funktion slugify in src/text.ts hinzu, mit Tests.
```
Opus schreibt `ds/arbeit/slugify.auftrag.md` und ruft den Bauleiter mit
`Name: slugify` auf. Danach bekommst du Bericht, Abnahme und Kosten.

Größere Aufgabe oder frische Sitzung:
```
Bauleiter-Plan: Protokoll auf Version 7 umstellen (Details …).
```
Opus schreibt einen Kurzauftrag, DeepSeek plant (`Phase: plan`), Opus liest
den Plan und schreibt eine Freigabe mit den Korrekturen, DeepSeek baut
(`Phase: bauen`) oder der Plan wird mit `ds/ds-worker.sh teilen` in Pakete
zerlegt.

## Stellschrauben (Umgebungsvariablen)

| Variable | Standard | Wirkung |
|---|---|---|
| `DS_KONTEXT` | 110000 | Kontextgröße, ab der eine frische Sitzung (Etappe) weitermacht, statt dass Claude Code zusammenfasst |
| `DS_ETAPPEN` | 4 | höchstens so viele Etappen je Lauf |
| `DS_LESEBUDGET` | `DS_KONTEXT`/2 | Kern-Lesebudget (Token), ab dem `start` zuerst vorerkundet (Lagekarte) |
| `DS_VORERKUNDUNG` | auto | `auto` (über dem Budget und bei Etappe ohne Fortschritt), `immer`, `aus` |
| `DS_ZEICHEN_JE_TOKEN` | 2,66 | Schätzfaktor des Lesebudgets (Read-Ausgabe, gemessen) |
| `DS_ZUEGE_MAX` / `DS_ZUEGE_RICHT` | 250 / 150 | Notbremse / Richtwert Züge je Sitzung |
| `DS_PLAN_ZUEGE` / `DS_PLAN_ZUEGE_MAX` | 60 / 100 | Richtwert / Grenze der Planphase |
| `DS_PAKETE` | 4 | höchstens so viele Pakete im Schnitt |
| `DS_MODEL`, `DS_EFFORT` | deepseek-flash, – | Modell, `--effort` (A/B-Messungen) |
| `DS_STILL`, `DS_API_STILL`, `DS_MAX`, `DS_PROBE` | 300, 90, 3600, 45 | Watchdog-Fristen in Sekunden |

## Exit-Codes von `ds-worker.sh`

| Code | Bedeutung |
|---|---|
| 0 | fertig (Bericht lesen: erledigt/teilweise) |
| 1 | Fehler oder Verweigerung (Auftrag unvollständig, Worktree existiert; `uebernehmen`: Rest offen) |
| 3 | Abbruch durch den Watchdog (Modell hängt) – später `nacharbeit` |
| 5 | Plan-Formprüfung fehlgeschlagen |
| 6 | zu groß: Etappe ohne Fortschritt (auch nach Vorerkundung) oder Etappengrenze – teilen oder Plan-Modus |

## Nur für dich statt für ein Projekt?

Die Werkzeuge (`ds/`) müssen im Projekt liegen, denn `ds-worker.sh` arbeitet
mit dessen git-Worktrees und Testbefehlen. Den Agenten kann man zusätzlich
nutzerweit ablegen (`~/.claude/agents/ds-bauleiter.md`), dann steht er in
jeder Sitzung bereit. Er funktioniert aber nur in Projekten mit installiertem
`ds/`. Empfehlung: je Projekt installieren, das hält Version und Projekt
zusammen.

## Aktualisieren und verbessern

- **Dieses Modul ist die Quelle.** Verbesserungen an Werkzeug-Dateien macht
  man hier in `vorlage/`, nicht im Projekt, und installiert dann neu:
  `./installieren.sh <projekt> --pruefen` zeigt den Unterschied,
  `./installieren.sh <projekt>` spielt ihn ein. Projektdateien bleiben
  unberührt.
- Wurde doch im Projekt geändert: mit `--pruefen` vergleichen und die Änderung
  hierher übernehmen, sonst überschreibt das nächste Installieren sie.
- Lernschleife je Lauf: siehe `vorlage/ds/LEHREN.md`. Lehren zu Werkzeug,
  Agent oder Hook gehören hierher, Lehren zu Aufträgen ins Projekt.

## Weitergeben

`bash paket.sh` erzeugt `dist/bauleiter.tar.gz`, das Modul ohne `.git`. Das
Skript bricht ab, wenn projektspezifische Stellen enthalten sind.

## Entfernen

`ds/` (außer eigenen Dateien), `.claude/agents/ds-bauleiter.md` und den
CLAUDE.md-Abschnitt löschen. Liegen gebliebene Worktrees räumt
`git worktree prune` auf; sie liegen unter `../<projekt>-ds/`.
