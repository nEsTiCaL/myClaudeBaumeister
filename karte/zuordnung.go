package main

import (
	"path"
	"strings"

	ts "github.com/tree-sitter/go-tree-sitter"
)

// Zuordnung eines Code-Treffers zu den Definitionen seines Namens.
//
// Exakt: Die Sprache laesst nur diese Definition zu. Go: unqualifiziert nur im
// selben Paket, qualifiziert ueber einen aufgeloesten Import. GDScript:
// unqualifiziert nur in der Datei selbst oder per extends, qualifiziert ueber
// const X = preload(...). Python: unqualifiziert in derselben Datei.
// Hinweis: Methodenaufruf auf einem Wert (Typ ohne Typpruefung unbekannt) oder
// Python ueber Importe. Fremd: keine Definition im Repo passt (flag.Parse).

type kandidat struct {
	pfad string
	s    symbol
}

type zuordnung struct {
	ziele []int  // Indizes in die Kandidaten
	exakt bool   // sonst Hinweis
	qual  string // Qualifier im Quelltext ("" unqualifiziert, "?" Ausdruck)
	modul bool   // qual ist ein Import-Alias (Paket, preload-Konstante)
}

var identArten = menge("identifier", "name", "package_identifier", "type_identifier")

// qualifier: Teil vor dem Punkt, wenn der Treffer das letzte Glied von a.b ist.
func qualifier(d *datei, node *ts.Node) string {
	x := node
	if p := x.Parent(); p != nil && p.Kind() == "attribute_call" { // GDScript a.f()
		x = p
	}
	m := x.Parent()
	if m == nil || !d.sp.member[m.Kind()] {
		return ""
	}
	var vorher *ts.Node
	for i := uint(0); i < m.NamedChildCount(); i++ {
		c := m.NamedChild(i)
		if gleich(c, x) {
			break
		}
		vorher = c
	}
	if vorher == nil {
		return "" // Treffer ist selbst der Anfang (a in a.b)
	}
	if !identArten[vorher.Kind()] || vorher.PrevNamedSibling() != nil {
		return "?" // a.b().f oder x[0].f: Typ unbekannt
	}
	return vorher.Utf8Text(d.src)
}

// erreichbar: Dateien, deren Definitionen in d unqualifiziert gelten.
func (r *repo) erreichbar(d *datei) map[string]bool {
	m := map[string]bool{d.pfad: true}
	switch d.sp.name {
	case "go":
		for _, f := range r.dateien {
			if path.Dir(f) == path.Dir(d.pfad) && strings.HasSuffix(f, ".go") {
				m[f] = true
			}
		}
	case "gdscript": // extends-Kette
		for cur := d; cur != nil; {
			var naechste *datei
			for _, imp := range cur.importe {
				if !imp.erbt {
					continue
				}
				for _, z := range r.aufloesen(cur, imp.ziel) {
					if !m[z] {
						m[z] = true
						naechste, _ = lies(z)
					}
				}
			}
			cur = naechste
		}
	}
	return m
}

// ueberAlias: Dateien, die d unter dem Namen q anspricht (Import-Alias, preload-Konstante).
func (r *repo) ueberAlias(d *datei, q string) (map[string]bool, bool) {
	m := map[string]bool{}
	gefunden := false
	for _, imp := range d.importe {
		if imp.alias != q {
			continue
		}
		gefunden = true
		for _, z := range r.aufloesen(d, imp.ziel) {
			m[z] = true
		}
	}
	return m, gefunden
}

func (r *repo) zuordnen(d *datei, node *ts.Node, kands []kandidat) zuordnung {
	q := qualifier(d, node)
	z := zuordnung{qual: q}
	alle := func(bed func(k kandidat) bool) {
		for i, k := range kands {
			if bed(k) {
				z.ziele = append(z.ziele, i)
			}
		}
	}
	methode := func(k kandidat) bool { return k.s.parent != "" || spracheFuer(k.pfad).name == "gdscript" }

	if q == "" || q == "self" {
		erreich := r.erreichbar(d)
		alle(func(k kandidat) bool { return erreich[k.pfad] })
		z.exakt = len(z.ziele) > 0
		if !z.exakt && d.sp.name == "python" { // from x import f
			imp := map[string]bool{}
			for _, f := range r.importiert[d.pfad] {
				imp[f] = true
			}
			alle(func(k kandidat) bool { return imp[k.pfad] })
		}
		return z
	}
	if q != "?" {
		if ziel, ok := r.ueberAlias(d, q); ok {
			alle(func(k kandidat) bool { return ziel[k.pfad] })
			z.exakt, z.modul = true, true
			return z
		}
		if d.sp.name == "python" { // import modul; modul.f()
			for _, f := range r.importiert[d.pfad] {
				if strings.TrimSuffix(path.Base(f), ".py") == q {
					alle(func(k kandidat) bool { return k.pfad == f })
				}
			}
			if len(z.ziele) > 0 {
				return z
			}
		}
	}
	// Wert.f(): nur Methoden kommen in Frage, welche, weiss erst die Typpruefung
	alle(methode)
	return z
}

// normName: HudFeed, hud_feed und hudfeed gelten als gleich (Datei- vs. Klassenname).
func normName(s string) string {
	return strings.ToLower(strings.ReplaceAll(s, "_", ""))
}

// qualifiziertDurch: passt Qualifier q zu einer Definition (Typ, Paket, Datei)?
func qualifiziertDurch(q, pfad string, s symbol) bool {
	if s.parent == q {
		return true
	}
	if s.parent != "" {
		return false
	}
	stamm := strings.TrimSuffix(path.Base(pfad), path.Ext(pfad))
	return path.Base(path.Dir(pfad)) == q || normName(stamm) == normName(q)
}
