package main

import (
	"bytes"
	"os"
	"os/exec"
	"strings"

	ts "github.com/tree-sitter/go-tree-sitter"
)

// Trefferklassen von leser, in Ausgabereihenfolge.
const (
	kDefinition = "Definition"
	kAufruf     = "Aufruf"
	kReferenz   = "Referenz"
	kText       = "Text"  // String ist genau der Name: dynamischer Bezug
	kProsa      = "Prosa" // Name in laengerem String (Meldung, Doku)
	kKommentar  = "Kommentar"
	kAndere     = "Andere Datei"
)

type treffer struct {
	pfad    string
	zeile   uint
	bis     uint // nur Definition: letzte Zeile
	klasse  string
	in      string // umschliessendes Symbol
	inVon   uint   // Bereich des umschliessenden Symbols
	inBis   uint
	text    string // Quelltextzeile, gekuerzt
	hinweis bool   // Zuordnung nur vermutet (Methode auf Wert, Python-Import)
	nach    string // bei mehreren Zieldefinitionen: Datei der zugeordneten
	qual    string // ausgeblendet: Qualifier im Quelltext
}

const gWert = "Feld/Methode eines Werts"

func nurFunktionen(defs []treffer) bool {
	for _, t := range defs {
		if !strings.HasPrefix(t.text, "function ") && !strings.HasPrefix(t.text, "method ") {
			return false
		}
	}
	return len(defs) > 0
}

// suchziel: "name", "Typ.name", "datei:name" oder "datei:Typ.name".
type suchziel struct{ datei, parent, name string }

func parseZiel(arg string) suchziel {
	var z suchziel
	if i := strings.LastIndex(arg, ":"); i >= 0 {
		z.datei, arg = arg[:i], arg[i+1:]
	}
	if i := strings.LastIndex(arg, "."); i >= 0 {
		z.parent, arg = arg[:i], arg[i+1:]
	}
	z.name = arg
	return z
}

func (z suchziel) passt(pfad string, s symbol) bool {
	return s.name == z.name && (z.datei == "" || pfad == z.datei || strings.HasSuffix(pfad, "/"+z.datei)) &&
		(z.parent == "" || qualifiziertDurch(z.parent, pfad, s))
}

// wortDateien: Textdateien, in denen name als ganzes Wort vorkommt; auch
// unversionierte, aber keine ignorierten.
func wortDateien(name string) ([]string, error) {
	out, err := exec.Command("git", "grep", "--untracked", "-l", "-I", "-w", "-F", "-z", "-e", name).Output()
	if err != nil {
		if e, ok := err.(*exec.ExitError); ok && e.ExitCode() == 1 {
			return nil, nil // nichts gefunden
		}
		return nil, err
	}
	var d []string
	for _, f := range bytes.Split(out, []byte{0}) {
		if len(f) > 0 {
			d = append(d, string(f))
		}
	}
	return d, nil
}

func istWortzeichen(b byte) bool {
	return b == '_' || b >= '0' && b <= '9' || b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b >= 0x80
}

// vorkommen: Byte-Offsets von name als ganzes Wort in src.
func vorkommen(src []byte, name string) []uint {
	var out []uint
	n := []byte(name)
	for i := 0; ; {
		j := bytes.Index(src[i:], n)
		if j < 0 {
			return out
		}
		a, e := i+j, i+j+len(n)
		if (a == 0 || !istWortzeichen(src[a-1])) && (e == len(src) || !istWortzeichen(src[e])) {
			out = append(out, uint(a))
		}
		i = e
	}
}

func zeileBei(src []byte, off uint) (uint, string) {
	a := bytes.LastIndexByte(src[:off], '\n') + 1
	e := bytes.IndexByte(src[off:], '\n')
	if e < 0 {
		e = len(src) - int(off)
	}
	return uint(bytes.Count(src[:off], []byte("\n")) + 1), string(src[a : int(off)+e])
}

func kuerzen(s string, n int) string {
	s = strings.Join(strings.Fields(s), " ")
	if r := []rune(s); len(r) > n {
		return string(r[:n-1]) + "…"
	}
	return s
}

// ergebnis von suchen. fremd: ausgeblendete Code-Treffer je Qualifier/Grund.
type ergebnis struct {
	defs, rest  []treffer
	gleichnamig int // Definitionen des Namens, die nicht zum Ziel passen
	fremd       map[string][]treffer
}

// suchen: alle Vorkommen von z.name, eingeordnet und den Definitionen zugeordnet.
func (r *repo) suchen(z suchziel) (*ergebnis, error) {
	dateien, err := wortDateien(z.name)
	if err != nil {
		return nil, err
	}
	e := &ergebnis{fremd: map[string][]treffer{}}
	var kands []kandidat
	zielIdx := map[int]bool{}
	for _, f := range dateien { // erst alle Definitionen des Namens
		d, err := lies(f)
		if err != nil {
			return nil, err
		}
		if d == nil {
			continue
		}
		for _, s := range d.symbole {
			if s.name != z.name {
				continue
			}
			if z.passt(f, s) {
				zielIdx[len(kands)] = true
				e.defs = append(e.defs, treffer{pfad: f, zeile: s.von, bis: s.bis, klasse: kDefinition,
					text: s.art + " " + s.voll() + sigTeil(s.sig)})
			} else {
				e.gleichnamig++
			}
			kands = append(kands, kandidat{pfad: f, s: s})
		}
	}
	for _, f := range dateien {
		d, _ := lies(f)
		if d == nil { // nicht geparst: Szenen, Doku, Konfiguration
			src, err := os.ReadFile(f)
			if err != nil {
				continue
			}
			for _, off := range vorkommen(src, z.name) {
				nr, txt := zeileBei(src, off)
				e.rest = append(e.rest, treffer{pfad: f, zeile: nr, klasse: kAndere, text: kuerzen(txt, 90)})
			}
			continue
		}
		defAn := map[uint]bool{}
		for _, k := range kands {
			if k.pfad == f {
				defAn[k.s.nameByte] = true
			}
		}
		for _, off := range vorkommen(d.src, z.name) {
			if defAn[off] {
				continue
			}
			nr, txt := zeileBei(d.src, off)
			t := treffer{pfad: f, zeile: nr, text: kuerzen(txt, 90)}
			if u := d.umgebend(nr); u != nil {
				t.in, t.inVon, t.inBis = u.voll(), u.von, u.bis
			}
			node := d.baum.RootNode().NamedDescendantForByteRange(off, off+uint(len(z.name)))
			t.klasse = einordnen(d, node, z.name)
			if t.klasse == kText && nurFunktionen(e.defs) && !alsArgument(d.sp, node) {
				t.klasse = kProsa // "name" als Datenschluessel meint keine Funktion
			}
			if t.klasse == kReferenz && deklariertAnderes(d.sp, node) {
				e.fremd["gleichnamige Deklaration (Feld, Parameter, lokal)"] = append(
					e.fremd["gleichnamige Deklaration (Feld, Parameter, lokal)"], t)
				continue
			}
			if (t.klasse == kAufruf || t.klasse == kReferenz) && len(kands) > 0 {
				zu := r.zuordnen(d, node, kands)
				var treffen []int
				for _, i := range zu.ziele {
					if zielIdx[i] {
						treffen = append(treffen, i)
					}
				}
				wert := zu.qual != "" && zu.qual != "self" && !zu.modul
				grund := ""
				switch {
				case len(treffen) > 0 && wert && t.klasse == kReferenz && nurFunktionen(e.defs):
					grund = gWert // x.f ohne Aufruf: Feld des Werts, nicht die Funktion
				case len(treffen) > 0:
				case len(zu.ziele) > 0:
					grund = "andere Definition gleichen Namens"
				case zu.modul:
					grund = "anderes Paket/Datei: " + zu.qual + "." + z.name
				case wert:
					grund = gWert
				default:
					grund = "nicht im Repo definiert (lokal, extern, eingebaut)"
				}
				if grund != "" {
					t.qual = zu.qual
					e.fremd[grund] = append(e.fremd[grund], t)
					continue
				}
				t.hinweis = !zu.exakt
				if len(e.defs) > 1 && len(treffen) == 1 {
					t.nach = kands[treffen[0]].pfad
				}
			}
			e.rest = append(e.rest, t)
		}
	}
	return e, nil
}

// einordnen: Klasse eines Vorkommens anhand seines Syntaxknotens.
func einordnen(d *datei, node *ts.Node, name string) string {
	sp := d.sp
	if node == nil {
		return kReferenz
	}
	for a := node; a != nil; a = a.Parent() {
		k := a.Kind()
		if sp.einschub[k] {
			break // Code in einem String (f-String): weiter als Code
		}
		if strings.Contains(k, "comment") {
			return kKommentar
		}
		if sp.text[k] {
			// alleinstehender String (Docstring) ist Kommentar, nicht Code
			if p := a.Parent(); p != nil && p.Kind() == "expression_statement" && p.NamedChildCount() == 1 {
				return kKommentar
			}
			if inhalt := strings.Trim(a.Utf8Text(d.src), "&^$%\"'`"); inhalt == name || !strings.Contains(a.Kind(), "string") {
				return kText // "name", &"name", $Pfad
			}
			return kProsa
		}
	}
	// Aufruf: der Name ist der Callee, ggf. als letztes Glied von a.b.name
	cur := node
	for p := cur.Parent(); p != nil; p = cur.Parent() {
		if sp.member[p.Kind()] {
			if letztes := p.NamedChild(p.NamedChildCount() - 1); letztes != nil && gleich(letztes, cur) {
				cur = p
				continue
			}
			break
		}
		if sp.aufruf[p.Kind()] {
			fn := p.ChildByFieldName("function")
			if fn == nil {
				fn = p.NamedChild(0)
			}
			if fn != nil && gleich(fn, cur) {
				return kAufruf
			}
		}
		break
	}
	return kReferenz
}

func gleich(a, b *ts.Node) bool {
	return a.StartByte() == b.StartByte() && a.EndByte() == b.EndByte() && a.Kind() == b.Kind()
}

// deklariertAnderes: Treffer ist der Name einer Deklaration, die kein Symbol der
// Karte ist (Struct-Feld, Parameter, lokale Variable) -- gleicher Name, anderes Ding.
func deklariertAnderes(sp *sprache, node *ts.Node) bool {
	p := node.Parent()
	if p == nil || sp.member[p.Kind()] { // paket.Name: Bezug, keine Deklaration
		return false
	}
	n := p.ChildByFieldName("name")
	return n != nil && gleich(n, node)
}

// alsArgument: String steht als Argument eines Aufrufs (call_deferred("f"),
// connect("f")) oder ist ein StringName/Szenenpfad.
func alsArgument(sp *sprache, node *ts.Node) bool {
	for a := node; a != nil; a = a.Parent() {
		switch k := a.Kind(); {
		case k == "string_name" || k == "node_path" || k == "get_node":
			return true
		case k == "arguments" || k == "argument_list":
			return true
		case sp.text[k]:
			continue
		case strings.Contains(k, "string"):
			continue
		default:
			return false
		}
	}
	return false
}
