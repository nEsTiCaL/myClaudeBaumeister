# Auftrag: <kurzer Titel>
<!-- Opus schreibt diese Datei direkt als ds/arbeit/<name>.auftrag.md; der
     Bauleiter aendert sie nicht. Zeilen mit <...> ersetzen oder loeschen --
     `start` verweigert unausgefuellte Vorlagenzeilen. Nur schreiben, was der
     Arbeiter nicht selbst findet: Entscheidungen, Zahlen, Vertraege, Grenzen. -->

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
- <Wiederhol-, Grenz-, Leer-, Fehlerfall -> erwartetes Verhalten; je Fall ein Test>

## Abnahme
Diese Befehle muessen gruen sein (`ds/ds-worker.sh pruefen` fuehrt sie aus,
je Zeile ein Befehl, aus der Repo-Wurzel):
```sh
<z. B. npm test>
```
- [ ] <neuer Test, der X prueft>
