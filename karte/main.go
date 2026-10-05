// karte: Struktur eines Repos aus dem Syntaxbaum (tree-sitter), damit Opus
// Fundstellen, Gliederungen und Leser kennt, ohne Quelltext zu lesen.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

const hilfe = `karte -- Struktur des Repos aus dem Syntaxbaum (Go, GDScript, Python)

  karte dateien [pfad...]        Uebersicht: ohne Pfad je Verzeichnis, sonst je Datei
                                 (Zeilen, ~Token ganz gelesen, Symbole, Importe <-von ->nach)
  karte gliederung [--alle] pfad...
                                 Symbole mit Zeilenbereich (--alle: auch var/const)
  karte symbol ziel              Definitionen: datei:von-bis art name(signatur)
  karte leser [--alle] ziel      Vorkommen eingeordnet: Definition, Aufruf, Referenz,
                                 Text (in Strings: dynamisch!), Kommentar, andere Dateien
  karte index [--max-zeichen N] pfad...
                                 je Datei eine Zeile: Struktur-Symbole mit Zeilenbereich
  karte verwendung [--max-zeichen N] ziel
                                 knapp: Definition, Aufrufe/Referenzen je Symbol, Text, Rest
                                 (Exit 2 ohne Definition; Ausgabe auf N Zeichen begrenzt)

  ziel: name | Typ.name | datei:name | datei:Typ.name
  Aufrufe und Referenzen sind namensbasiert (Hinweis, kein Beweis); Definitionen,
  Zeilenbereiche und aufgeloeste Importe sind exakt. Pfade relativ zum Aufruf.
`

const proKlasse = 25 // Zeilen je Trefferklasse ohne --alle

func zeichenJeToken() float64 {
	if f, err := strconv.ParseFloat(strings.ReplaceAll(os.Getenv("DS_ZEICHEN_JE_TOKEN"), ",", "."), 64); err == nil && f > 0 {
		return f
	}
	return 2.66
}

func itoa(n uint) string { return strconv.FormatUint(uint64(n), 10) }

func kTok(t int) string {
	if t < 1000 {
		return "<1k"
	}
	return fmt.Sprintf("%dk", (t+500)/1000)
}

func fehler(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "karte: "+format+"\n", a...)
	os.Exit(1)
}

// zahlArg: positive Zahl fuer --max-zeichen.
func zahlArg(s string) int {
	n, err := strconv.Atoi(s)
	if err != nil || n <= 0 {
		fehler("--max-zeichen: ungueltige Zahl %q", s)
	}
	return n
}

func main() {
	args := os.Args[1:]
	if len(args) == 0 || args[0] == "-h" || args[0] == "--help" || args[0] == "hilfe" {
		fmt.Print(hilfe)
		return
	}
	cmd, args := args[0], args[1:]
	alle := false
	maxZeichen := 0 // 0: Standard des Befehls
	var rest []string
	for i := 0; i < len(args); i++ {
		switch a := args[i]; {
		case a == "--alle":
			alle = true
		case a == "--max-zeichen":
			if i+1 >= len(args) {
				fehler("--max-zeichen braucht eine Zahl")
			}
			i++
			maxZeichen = zahlArg(args[i])
		case strings.HasPrefix(a, "--max-zeichen="):
			maxZeichen = zahlArg(strings.TrimPrefix(a, "--max-zeichen="))
		default:
			rest = append(rest, a)
		}
	}
	wurzel, err := exec.Command("git", "rev-parse", "--show-toplevel").Output()
	if err != nil {
		fehler("kein git-Repository")
	}
	// Pfadangaben relativ zum Aufruf -> relativ zur Repo-Wurzel
	relativ := func(p string) string {
		abs, _ := filepath.Abs(p)
		rel, err := filepath.Rel(strings.TrimSpace(string(wurzel)), abs)
		if err != nil {
			return p
		}
		return filepath.ToSlash(rel)
	}
	for i, a := range rest {
		if cmd == "symbol" || cmd == "leser" || cmd == "verwendung" {
			if j := strings.LastIndex(a, ":"); j >= 0 {
				rest[i] = relativ(a[:j]) + a[j:]
			}
		} else if cmd != "baum" {
			rest[i] = relativ(a)
		}
	}
	if cmd != "baum" {
		if err := os.Chdir(strings.TrimSpace(string(wurzel))); err != nil {
			fehler("%v", err)
		}
	}

	switch cmd {
	case "dateien":
		r := mussRepo()
		if len(rest) == 0 {
			verzeichnisse(r)
		} else {
			dateien(r, rest)
		}
	case "gliederung":
		if len(rest) == 0 {
			fehler("gliederung braucht einen Pfad")
		}
		gliederung(mussRepo(), rest, alle)
	case "symbol":
		if len(rest) != 1 {
			fehler("symbol braucht genau ein Ziel")
		}
		symbole(mussRepo(), parseZiel(rest[0]))
	case "leser":
		if len(rest) != 1 {
			fehler("leser braucht genau ein Ziel")
		}
		leser(mussRepo(), parseZiel(rest[0]), alle)
	case "index":
		if len(rest) == 0 {
			fehler("index braucht mindestens einen Pfad")
		}
		fmt.Print(index(mussRepo(), rest, maxZeichenOder(maxZeichen, stdIndex)))
	case "verwendung":
		if len(rest) != 1 {
			fehler("verwendung braucht genau ein Ziel")
		}
		text, gefunden, err := verwendung(mussRepo(), parseZiel(rest[0]), maxZeichenOder(maxZeichen, stdVerwendung))
		if err != nil {
			fehler("%v", err)
		}
		fmt.Print(text) // ohne Definition: keine Ausgabe
		if !gefunden {
			os.Exit(2)
		}
	case "baum": // Entwicklung: Syntaxbaum einer Datei (fuer neue Queries)
		for _, f := range rest {
			d, err := lies(f)
			if err != nil || d == nil {
				fehler("%s: nicht lesbar oder Sprache nicht unterstuetzt (%v)", f, err)
			}
			fmt.Println(d.baum.RootNode().ToSexp())
		}
	default:
		fehler("unbekannter Befehl %q (karte hilfe)", cmd)
	}
}

func mussRepo() *repo {
	r, err := ladeRepo()
	if err != nil {
		fehler("git ls-files: %v", err)
	}
	if err := r.graph(); err != nil {
		fehler("%v", err)
	}
	return r
}

func mussLesen(f string) *datei {
	d, err := lies(f)
	if err != nil {
		fehler("%s: %v", f, err)
	}
	return d
}

func strukturZahl(d *datei) int {
	n := 0
	for _, s := range d.symbole {
		if s.struktur() {
			n++
		}
	}
	return n
}

func verzeichnisse(r *repo) {
	type summe struct{ dateien, zeilen, token, symbole int }
	je := map[string]*summe{}
	var gesamt summe
	for _, f := range r.quellen(nil) {
		d := mussLesen(f)
		v := path.Dir(f)
		if je[v] == nil {
			je[v] = &summe{}
		}
		for _, s := range []*summe{je[v], &gesamt} {
			s.dateien++
			s.zeilen += d.zeilen()
			s.token += d.token()
			s.symbole += strukturZahl(d)
		}
	}
	namen := make([]string, 0, len(je))
	for v := range je {
		namen = append(namen, v)
	}
	sort.Strings(namen)
	fmt.Printf("%-34s %7s %7s %7s %7s\n", "Verzeichnis", "Dateien", "Zeilen", "~Token", "Symbole")
	for _, v := range namen {
		s := je[v]
		fmt.Printf("%-34s %7d %7d %7s %7d\n", v+"/", s.dateien, s.zeilen, kTok(s.token), s.symbole)
	}
	fmt.Printf("%-34s %7d %7d %7s %7d\n", "gesamt", gesamt.dateien, gesamt.zeilen, kTok(gesamt.token), gesamt.symbole)
}

func dateien(r *repo, pfade []string) {
	q := r.quellen(pfade)
	if len(q) == 0 {
		fehler("keine unterstuetzten Dateien unter %s", strings.Join(pfade, " "))
	}
	fmt.Printf("%-42s %6s %6s %5s %4s %4s\n", "Datei", "Zeilen", "~Token", "Symb.", "<-", "->")
	for _, f := range q {
		d := mussLesen(f)
		fmt.Printf("%-42s %6d %6s %5d %4d %4d%s\n", f, d.zeilen(), kTok(d.token()), strukturZahl(d),
			len(r.importiertVon[f]), len(r.importiert[f]), kaputt(d))
	}
}

func kaputt(d *datei) string {
	if d.kaputt {
		return "  (Syntaxfehler, unvollstaendig)"
	}
	return ""
}

// kompakt: Dateiliste fuer eine Zeile; vollstaendige Go-Pakete als "dir/*.go".
func kompakt(r *repo, liste []string, max int) string {
	var out []string
	gesehen := map[string]bool{}
	for _, f := range liste {
		if strings.HasSuffix(f, ".go") {
			dir := path.Dir(f)
			if gesehen[dir] {
				continue
			}
			pk := r.paket(dir)
			n := 0
			for _, g := range liste {
				if path.Dir(g) == dir && strings.HasSuffix(g, ".go") && !strings.HasSuffix(g, "_test.go") {
					n++
				}
			}
			if len(pk) > 1 && n == len(pk) {
				gesehen[dir] = true
				out = append(out, dir+"/*.go")
				continue
			}
		}
		out = append(out, f)
	}
	if len(out) > max {
		return strings.Join(out[:max], ", ") + fmt.Sprintf(" … (+%d)", len(out)-max)
	}
	return strings.Join(out, ", ")
}

func gliederung(r *repo, pfade []string, alle bool) {
	q := r.quellen(pfade)
	if len(q) == 0 {
		fehler("keine unterstuetzten Dateien unter %s", strings.Join(pfade, " "))
	}
	for i, f := range q {
		d := mussLesen(f)
		if i > 0 {
			fmt.Println()
		}
		fmt.Printf("%s  %d Zeilen, ~%s Token%s\n", f, d.zeilen(), kTok(d.token()), kaputt(d))
		if v := r.importiertVon[f]; len(v) > 0 {
			fmt.Printf("  <- importiert von: %s\n", kompakt(r, v, 8))
		}
		if n := r.importiert[f]; len(n) > 0 {
			fmt.Printf("  -> importiert: %s\n", kompakt(r, n, 8))
		}
		var offen []symbol // umschliessende Struktur-Symbole fuer die Einrueckung
		for _, s := range d.symbole {
			if !alle && !s.struktur() {
				continue
			}
			for len(offen) > 0 && offen[len(offen)-1].bis < s.von {
				offen = offen[:len(offen)-1]
			}
			tiefe := len(offen)
			if s.parent != "" && tiefe > 0 {
				tiefe-- // Methode: Klasse steht schon im Namen
			}
			fmt.Printf("  %s%d-%d %s %s%s\n", strings.Repeat("  ", tiefe), s.von, s.bis, s.art, s.voll(), kuerzen(sigTeil(s.sig), 90))
			if s.struktur() && s.bis > s.von {
				offen = append(offen, s)
			}
		}
	}
}

// sigTeil: Parameter direkt am Namen, Typen/Basisklassen mit Abstand.
func sigTeil(sig string) string {
	if sig == "" || strings.HasPrefix(sig, "(") {
		return sig
	}
	return " " + sig
}

func symbole(r *repo, z suchziel) {
	e, err := r.suchen(z)
	if err != nil {
		fehler("%v", err)
	}
	if len(e.defs) == 0 {
		fehler("keine Definition fuer %s (gleichnamig anderswo: %d)", z.name, e.gleichnamig)
	}
	for _, t := range e.defs {
		fmt.Printf("%s:%d-%d %s\n", t.pfad, t.zeile, t.bis, kuerzen(t.text, 110))
	}
}

func leser(r *repo, z suchziel, alle bool) {
	e, err := r.suchen(z)
	if err != nil {
		fehler("%v", err)
	}
	for _, t := range e.defs {
		fmt.Printf("Definition  %s:%d-%d %s\n", t.pfad, t.zeile, t.bis, kuerzen(t.text, 100))
		if v := r.importiertVon[t.pfad]; len(v) > 0 {
			fmt.Printf("  Datei importiert von (%d): %s\n", len(v), kompakt(r, v, 10))
		}
	}
	if len(e.defs) == 0 {
		fmt.Printf("Definition  keine passende im Repo (extern, dynamisch, anderer Name; gleichnamig: %d)\n", e.gleichnamig)
	}
	if len(e.defs) > 1 {
		fmt.Printf("Achtung: %d Definitionen passen -- Ziel mit Typ./Paket./datei: eingrenzen.\n", len(e.defs))
	}
	je := map[string][]treffer{}
	for _, t := range e.rest {
		je[t.klasse] = append(je[t.klasse], t)
	}
	for _, k := range []string{kAufruf, kReferenz, kText, kProsa, kKommentar, kAndere} {
		ts := je[k]
		if len(ts) == 0 {
			continue
		}
		titel := fmt.Sprintf("%s (%d", k, len(ts))
		if n := zaehleHinweise(ts); n > 0 {
			titel += fmt.Sprintf(", davon %d Hinweis '?': Methode auf Wert, Typ unbekannt", n)
		}
		titel += ")"
		switch k {
		case kText:
			titel += " -- String/Szenenpfad genau dieser Name: dynamischer Bezug, kein Aufrufgraph sieht das"
		case kProsa:
			titel += " -- in Meldungen/Docstrings"
		case kAndere:
			titel += " -- nicht geparst: Szenen, Doku, Konfiguration"
		}
		fmt.Printf("\n%s\n", titel)
		if k == kKommentar || k == kProsa { // nur Fundstellen, je Datei eine Zeile
			fundstellenJeDatei(ts, alle)
			continue
		}
		trefferZeilen(ts, alle)
	}
	if len(e.fremd) > 0 {
		n := 0
		for _, ts := range e.fremd {
			n += len(ts)
		}
		fmt.Printf("\nAusgeblendet (%d, gehoeren nicht zum Ziel)\n", n)
		for _, g := range sortierteSchluessel(e.fremd) {
			ts := e.fremd[g]
			bsp := ""
			if g == gWert {
				var q []string
				gesehen := map[string]bool{}
				for _, t := range ts {
					if !gesehen[t.qual] && len(q) < 5 {
						gesehen[t.qual] = true
						q = append(q, strings.Replace(t.qual, "?", "(Ausdruck)", 1)+".")
					}
				}
				bsp = " (" + strings.Join(q, " ") + ")"
			}
			fmt.Printf("  %d %s%s\n", len(ts), g, bsp)
			if alle {
				trefferZeilen(ts, true)
			}
		}
	}
}

func zaehleHinweise(ts []treffer) int {
	n := 0
	for _, t := range ts {
		if t.hinweis {
			n++
		}
	}
	return n
}

func sortierteSchluessel(m map[string][]treffer) []string {
	var k []string
	for s := range m {
		k = append(k, s)
	}
	sort.Strings(k)
	return k
}

func trefferZeilen(ts []treffer, alle bool) {
	for i, t := range ts {
		if !alle && i == proKlasse {
			fmt.Printf("  … %d weitere (--alle)\n", len(ts)-proKlasse)
			return
		}
		mark, in, nach := " ", "", ""
		if t.hinweis {
			mark = "?"
		}
		if t.in != "" {
			in = " [" + t.in + "]"
		}
		if t.nach != "" {
			nach = "  -> " + t.nach
		}
		fmt.Printf(" %s%s:%d%s  %s%s\n", mark, t.pfad, t.zeile, in, t.text, nach)
	}
}

func fundstellenJeDatei(ts []treffer, alle bool) {
	var reihe []string
	zeilen := map[string][]string{}
	for _, t := range ts {
		if zeilen[t.pfad] == nil {
			reihe = append(reihe, t.pfad)
		}
		zeilen[t.pfad] = append(zeilen[t.pfad], itoa(t.zeile))
	}
	for i, f := range reihe {
		if !alle && i == 10 {
			fmt.Printf("  … %d weitere Dateien (--alle)\n", len(reihe)-10)
			return
		}
		fmt.Printf("  %s: %s\n", f, strings.Join(zeilen[f], ", "))
	}
}
