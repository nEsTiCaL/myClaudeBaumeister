package main

import (
	"fmt"
	"strings"
)

// Kurzfassungen fuer einen Hook: index (Struktur je Datei) und verwendung
// (Fundstellen eines Namens). Beide Ausgaben sind auf --max-zeichen begrenzt.

const (
	stdIndex      = 6000
	stdVerwendung = 2500
)

// maxZeichenOder: Standardbudget, wenn --max-zeichen nicht gesetzt ist.
func maxZeichenOder(n, standard int) int {
	if n > 0 {
		return n
	}
	return standard
}

// index: je Datei eine Zeile mit den Struktur-Symbolen (Name, Zeilenbereich),
// in Argumentreihenfolge, Doppelte einmal. Leer, wenn nichts Verwertbares.
func index(r *repo, pfade []string, max int) string {
	type dateiZeile struct{ pfad, text string }
	var zeilen []dateiZeile
	gesehen := map[string]bool{}
	for _, p := range pfade {
		if p == "" || gesehen[p] || !r.gibt[p] { // Verzeichnisse, fehlende, ignorierte
			continue
		}
		gesehen[p] = true
		d, err := lies(p)
		if err != nil || d == nil { // nicht unterstuetzte Dateien
			continue
		}
		zeilen = append(zeilen, dateiZeile{p, indexZeile(d)})
	}
	var b strings.Builder
	i := 0
	for ; i < len(zeilen); i++ {
		if zeilePasst(&b, max, zeilen[i].text) {
			continue
		}
		// Passt die Zeile nicht mehr ganz: am letzten ganzen Eintrag kuerzen.
		if s, ok := kuerzeEintraege(zeilen[i].text, max-b.Len()); ok {
			b.WriteString(s + "\n")
			i++
		}
		break
	}
	if i < len(zeilen) { // letzte Zeile zaehlt nicht gegen das Budget
		var rest []string
		for _, z := range zeilen[i:] {
			rest = append(rest, z.pfad)
		}
		b.WriteString("… nicht gezeigt: " + strings.Join(rest, ", ") + "\n")
	}
	return b.String()
}

// zeilePasst haengt die Zeile an, wenn sie ganz ins Budget passt.
func zeilePasst(b *strings.Builder, max int, s string) bool {
	if b.Len()+len(s)+1 > max {
		return false
	}
	b.WriteString(s + "\n")
	return true
}

// indexZeile: "<pfad>: <voll> <von>-<bis>, ..." nur Struktur-Symbole; ohne
// solche "<pfad>: -".
func indexZeile(d *datei) string {
	var teile []string
	for _, s := range d.symbole {
		if s.struktur() {
			teile = append(teile, fmt.Sprintf("%s %d-%d", s.voll(), s.von, s.bis))
		}
	}
	if len(teile) == 0 {
		return d.pfad + ": -"
	}
	return d.pfad + ": " + strings.Join(teile, ", ")
}

// kuerzeEintraege: "<kopf>: eintrag, ..." bis zum letzten ganzen Eintrag
// kuerzen und " …(+K)" anhaengen, wenn mindestens ein Eintrag passt.
// platz: Zeichen, die samt Zeilenende noch ins Budget passen.
func kuerzeEintraege(text string, platz int) (string, bool) {
	i := strings.Index(text, ": ")
	if i < 0 {
		return "", false
	}
	kopf, teile := text[:i+2], strings.Split(text[i+2:], ", ")
	if platz < 0 || len(teile) < 2 {
		return "", false
	}
	for j := len(teile) - 1; j >= 1; j-- {
		s := kopf + strings.Join(teile[:j], ", ") + fmt.Sprintf(" …(+%d)", len(teile)-j)
		if len(s)+1 <= platz {
			return s, true
		}
	}
	return "", false
}

// verwendung: kompakte Fassung von leser. gefunden false: keine Definition im
// Repo (Aufrufer bleibt dann still und beendet mit Exit 2).
func verwendung(r *repo, z suchziel, max int) (string, bool, error) {
	e, err := r.suchen(z)
	if err != nil {
		return "", false, err
	}
	if len(e.defs) == 0 {
		return "", false, nil
	}
	var b strings.Builder
	for _, t := range e.defs { // Definitionen stehen immer, auch knapp im Budget
		fmt.Fprintf(&b, "Definition %s: %s:%d-%d %s\n", z.name, t.pfad, t.zeile, t.bis, kuerzen(t.text, 100))
	}
	if len(e.defs) > 1 {
		fmt.Fprintf(&b, "Achtung: %d Definitionen passen\n", len(e.defs))
	}
	var aufrufe, referenzen, texte []treffer
	for _, t := range e.rest {
		switch t.klasse {
		case kAufruf:
			aufrufe = append(aufrufe, t)
		case kReferenz:
			referenzen = append(referenzen, t)
		case kText:
			texte = append(texte, t)
		}
	}
	var zeilen []ausZeile
	for _, g := range []ausZeile{
		{kopf: "Aufrufe:", teile: gruppenZeilen(aufrufe)},
		{kopf: "Referenzen:", teile: gruppenZeilen(referenzen)},
		{kopf: "Text (dynamisch):", teile: fundstellenZeilen(texte)},
	} {
		if len(g.teile) > 0 { // leere Zeile weglassen
			zeilen = append(zeilen, g)
		}
	}
	if s := sonstZeile(e); s != "" {
		zeilen = append(zeilen, ausZeile{kopf: s})
	}
	for _, z := range zeilen {
		if !z.schreibe(&b, max) {
			break // gekuerzt oder passte nicht: danach nichts mehr
		}
	}
	return b.String(), true, nil
}

// ausZeile: eine Ausgabezeile aus Kopf und Teilen (Gruppen, Fundstellen);
// ohne Teile ist der Kopf die ganze Zeile.
type ausZeile struct {
	kopf  string
	teile []string
}

func (z ausZeile) text() string {
	switch {
	case len(z.teile) == 0:
		return z.kopf
	case z.kopf == "":
		return strings.Join(z.teile, ", ")
	}
	return z.kopf + " " + strings.Join(z.teile, ", ")
}

func (z ausZeile) textBis(j int) string {
	s := z.kopf
	if s != "" {
		s += " "
	}
	return s + strings.Join(z.teile[:j], ", ") + fmt.Sprintf(" …(+%d)", len(z.teile)-j)
}

// schreibe haengt die Zeile ans Budget an. false: die Zeile wurde gekuerzt oder
// passte gar nicht -- danach nichts weiteres schreiben.
func (z ausZeile) schreibe(b *strings.Builder, max int) bool {
	if zeilePasst(b, max, z.text()) {
		return true
	}
	for j := len(z.teile) - 1; j >= 1; j-- { // am letzten ganzen Teil kuerzen
		if s := z.textBis(j); b.Len()+len(s)+1 <= max {
			b.WriteString(s + "\n")
			return false
		}
	}
	return false
}

// gruppenZeilen: Treffer nach (Datei, umschliessendes Symbol) gruppieren,
// Gruppe in Reihenfolge des ersten Treffers; ohne Symbol "Dateiebene".
func gruppenZeilen(ts []treffer) []string {
	type gruppe struct {
		pfad         string
		in           string
		inVon, inBis uint
	}
	var reihe []gruppe
	je := map[gruppe][]string{}
	for _, t := range ts {
		g := gruppe{t.pfad, t.in, t.inVon, t.inBis}
		if _, ok := je[g]; !ok {
			reihe = append(reihe, g)
		}
		nr := itoa(t.zeile)
		if t.hinweis {
			nr += "?"
		}
		je[g] = append(je[g], nr)
	}
	var out []string
	for _, g := range reihe {
		if g.in == "" {
			out = append(out, fmt.Sprintf("%s Dateiebene (%s)", g.pfad, strings.Join(je[g], ", ")))
			continue
		}
		out = append(out, fmt.Sprintf("%s %s %d-%d (%s)", g.pfad, g.in, g.inVon, g.inBis, strings.Join(je[g], ", ")))
	}
	return out
}

func fundstellenZeilen(ts []treffer) []string {
	var out []string
	for _, t := range ts {
		out = append(out, fmt.Sprintf("%s:%d", t.pfad, t.zeile))
	}
	return out
}

// sonstZeile: Anzahlen der uebrigen Klassen und der ausgeblendeten Treffer;
// Nullen und die ganze Zeile weg, wenn alles 0 ist.
func sonstZeile(e *ergebnis) string {
	n := map[string]int{}
	for _, t := range e.rest {
		switch t.klasse {
		case kProsa, kKommentar, kAndere:
			n[t.klasse]++
		}
	}
	var teile []string
	for _, k := range []string{kProsa, kKommentar, kAndere} {
		if n[k] > 0 {
			teile = append(teile, fmt.Sprintf("%s %d", k, n[k]))
		}
	}
	fremd := 0
	for _, ts := range e.fremd {
		fremd += len(ts)
	}
	if fremd > 0 {
		teile = append(teile, fmt.Sprintf("ausgeblendet %d", fremd))
	}
	if len(teile) == 0 {
		return ""
	}
	return "Sonst: " + strings.Join(teile, ", ")
}
