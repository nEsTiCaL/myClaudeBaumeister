# Der Bauleiter – Kurzanleitung (ganz einfach erklärt)

## Was ist das?

Stell dir eine Baustelle vor:

- **Die Architektin** (Claude Opus) ist klug und teuer. Sie weiß, wie das Haus
  aussehen soll, und schaut am Ende nach, ob alles stimmt.
- **Der Handwerker** (DeepSeek) ist fleißig und sehr günstig. Er mauert, was
  auf dem Zettel steht, in seiner eigenen Werkstatt, damit er nichts kaputt macht.
- **Der Bauleiter** (Claude Haiku) schickt den Handwerker mit dem Zettel der
  Architektin los, wartet, prüft mit einer Checkliste, ob alles grün ist, und
  schickt ihn notfalls noch einmal los. Den Zettel ändern darf er nicht –
  nur weitergeben und melden. So muss die Architektin nicht danebenstehen.

Die Architektin muss also nicht selbst mauern. Das spart Geld: in 38
Läufen kostete ein Auftrag **0,30–2,80 $** (meist um 1 $) statt geschätzt
**0,50–14 $**, wenn Opus alles selbst gebaut hätte.

## Was brauchst du?

- Linux (macOS geht mit GNU-Werkzeugen: `coreutils`, neues `bash`)
- [Claude Code](https://claude.com/claude-code), `git`, `jq`, `curl`, `python3`
- einen DeepSeek-API-Schlüssel (platform.deepseek.com)
- ein Git-Projekt mit Tests, die man per Befehl starten kann

## Einrichten (einmal, ca. 10 Minuten)

Die genauen Schritte stehen in der [README.md](README.md). Kurz:

1. **Schlüssel ablegen** in `~/.config/deepseek/env` (nie ins Projekt).
2. **Installieren:** `./installieren.sh /pfad/zu/deinem/projekt` kopiert
   alles an die richtige Stelle und prüft, ob etwas fehlt.
3. **Dein Projekt eintragen:** in `ds/projekt.sh` sagen, welche Testbefehle
   der Handwerker benutzen darf (z. B. `npm test`, `go test`, `pytest`) und wie
   eine einzelne Datei nach dem Bearbeiten schnell geprüft wird (`nach_edit`).
   Dann sieht der Handwerker Fehler sofort statt erst nach hundert Schritten.
4. **Die Architektin einweisen:** den Text aus `CLAUDE-baustein.md` in die
   `CLAUDE.md` deines Projekts kopieren.
5. **Claude Code neu starten** (sonst kennt es den Bauleiter noch nicht).

## Benutzen

Schreib in Claude Code einfach:

> **Bauleiter:** Füge eine Funktion `slugify` in `src/text.ts` hinzu, mit Tests.

Dann passiert Folgendes von allein:

1. Opus klärt mit dir offene Fragen und schreibt den Auftrag als Datei
   (`ds/arbeit/<name>.auftrag.md`).
2. Der Bauleiter startet DeepSeek damit, wartet und prüft die Tests.
3. Du bekommst einen Bericht: was gebaut wurde, ob alles grün ist, was es gekostet hat.
4. Opus schaut sich heikle Stellen an und holt die Arbeit in dein Projekt.
   **Committen tust du** – oder Opus, wenn du es sagst.

**Zweiter Weg für größere Sachen:**

> **Bauleiter-Plan:** Stell das Protokoll auf Version 7 um (…).

Hier läuft die Architektin nicht selbst durchs Haus. Sie schreibt nur auf,
*was* sie will und was feststeht. Der Handwerker geht durchs Haus und
schreibt einen Plan: welche Stellen, was er entscheiden würde, was er nicht
weiß. Die Architektin liest nur den Plan, streicht Falsches an und gibt ihn
frei. Erst dann baut der Handwerker. Ist es viel Arbeit, teilt ein Skript
den Plan in bis zu vier Pakete.

## Wann lohnt sich was?

- **Ganz klein** (Opus wäre in ein paar Schritten fertig): Opus macht es
  selbst. Der Bauleiter kostet immer etwa 1 $ Grundbetrag.
- **Opus kennt die Stellen schon:** `Bauleiter:`.
- **Opus müsste erst suchen, oder es wird groß:** `Bauleiter-Plan:`.

## Gut zu wissen

- **Klein und klar** klappt am besten: „baue X in Datei Y, Test Z muss grün
  sein“. Für „überleg dir mal eine Architektur“ ist der Bauleiter falsch.
- DeepSeek arbeitet in einem **eigenen Ordner** neben deinem Projekt
  (`<projekt>-ds/<name>`). Dein Projekt bleibt unberührt, bis Opus übernimmt.
- Wenn DeepSeek hängt, bricht das Werkzeug nach kurzer Zeit selbst ab
  (keine Endlosschleife, keine Endloskosten). Mehr als 250 Schritte sind
  gesperrt; dann ist der Auftrag zu groß – lieber in zwei teilen.
- Wird DeepSeeks „Gedächtnis“ zu voll, macht ein frischer DeepSeek weiter
  und bekommt den Zettel vollständig mit (Etappe). So geht beim Aufräumen
  des Gedächtnisses keine Entscheidung verloren.
- Muss DeepSeek für einen Auftrag sehr viel lesen, schaut erst ein
  „Erkunder“ nach und schreibt eine Lagekarte: wo genau im Code was steht.
  Der Bauer liest dann nur noch diese Stellen. Kommt trotzdem nichts voran,
  bricht das Werkzeug ab und sagt „zu groß – teilen“, statt im Kreis zu
  laufen. Wie viel ein Auftrag zu lesen hat, zeigt `ds/ds-worker.sh budget <name>`.
- Von Hand geht alles auch: `ds/ds-worker.sh` ohne Argumente zeigt die Befehle.
- Wer wissen will, *warum* das so gebaut ist: `ERKLAERUNG-AI-ENGINEERING.md`.
