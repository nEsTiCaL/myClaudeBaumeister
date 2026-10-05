# Auftrag: <kurzer Titel>
<!-- Opus schreibt diese Datei direkt als ds/arbeit/<name>.auftrag.md; der
     Bauleiter aendert sie nicht. Zeilen mit <...> ersetzen oder loeschen --
     `start` verweigert unausgefuellte Vorlagenzeilen. Nur schreiben, was der
     Arbeiter nicht selbst findet: Entscheidungen, Zahlen, Vertraege, Grenzen.
     Lesebudget: `ds/ds-worker.sh budget NAME` zaehlt die Dateien aus Aendern,
     LOESCHEN, Lies zuerst und Einstiegsstellen (Kern); ueber ~55k erkundet
     start zuerst vor, ueber ~110k lieber teilen. Andere Dateien nur nennen. -->

## Ziel
<Ein bis drei Saetze: was soll danach anders sein, aus Nutzersicht oder als
messbares Verhalten.>

## Kontext
- Lies zuerst: <Doku/Gedaechtnis-Dateien, z. B. docs/architektur.md>
- Einstiegsstellen: <datei:zeile -- was dort passiert>
- Muster zum Nachahmen: <bestehende Funktion/Test, an der man sich orientiert>

## Umfang
- Aendern: <Dateien>
- Alle Leser: <bei geaenderter Signatur/Codec/Raster/Flag-Bedeutung: jede Fundstelle (grep), auch Tests, Tools, JS>
- NICHT anfassen: <Dateien/Bereiche, die ein paralleler Auftrag aendert>

## Vorgaben
- <Konstanten, Namen, Signaturen, Formeln, Reihenfolgen -- alles, was nicht offen ist>

## Randfaelle
<!-- Pruefliste aus den Lehren (je zutreffender Punkt ein Fall mit Test):
     Wiederholfall bei Zustandsmerkern (zweimal hintereinander, direkt nach
     Ablauf) | "Verhalten unveraendert" -> Test, der es festnagelt | Vorrang,
     wenn zwei Teile sich ueberlagern | Reihenfolge (erst X, dann Y) | Formel
     statt Worten (Wrap, Rundung, Einheit, Aufloesung) | mehrdeutige Begriffe
     definieren | Rueckgabe/Flags je Fall eindeutig -->
- <Wiederhol-, Grenz-, Leer-, Fehlerfall -> erwartetes Verhalten; je Fall ein Test>

## Abnahme
Diese Befehle muessen gruen sein (`ds/ds-worker.sh pruefen` fuehrt sie aus,
je Zeile ein Befehl, aus der Repo-Wurzel):
```sh
<z. B. npm test>
```
- [ ] <neuer Test, der X prueft>
