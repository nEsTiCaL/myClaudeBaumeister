package main

import (
	"bytes"
	"os"
	"path"
	"sort"
	"strings"

	ts "github.com/tree-sitter/go-tree-sitter"
)

// importAngabe: roh aus dem Quelltext; aufgeloest wird in repo.aufloesen.
type importAngabe struct {
	ziel  string // Pfad, Paket oder Modul
	alias string // Name, ueber den die Datei das Ziel anspricht (leer: keiner/Standard)
	erbt  bool   // GDScript extends: Methoden des Ziels unqualifiziert erreichbar
}

// symbol: eine Definition mit Zeilenbereich (1-basiert, inklusive).
type symbol struct {
	name, art, sig, parent string
	von, bis               uint
	nameByte               uint // Beginn des Bezeichners: Treffer dort = Definition
	pattern                uint
}

func (s symbol) voll() string {
	if s.parent != "" {
		return s.parent + "." + s.name
	}
	return s.name
}

// struktur: Symbole, die eine Gliederung tragen (ohne var/const).
func (s symbol) struktur() bool { return s.art != "var" && s.art != "const" }

// datei: geparste Quelldatei. Pfad relativ zur Repo-Wurzel.
type datei struct {
	pfad    string
	src     []byte
	sp      *sprache
	baum    *ts.Tree
	symbole []symbol
	importe []importAngabe
	kaputt  bool     // Syntaxfehler: Ergebnis unvollstaendig
}

func (d *datei) zeilen() int {
	n := bytes.Count(d.src, []byte("\n"))
	if len(d.src) > 0 && d.src[len(d.src)-1] != '\n' {
		n++
	}
	return n
}

// token schaetzt die Token, wenn die Datei ganz gelesen wird (wie ds/plan.py).
func (d *datei) token() int {
	return int(float64(len(d.src)+7*d.zeilen()) / zeichenJeToken())
}

var cache = map[string]*datei{}

// lies parst eine Datei (gecacht). nil, nil: Sprache nicht unterstuetzt.
func lies(pfad string) (*datei, error) {
	if d, ok := cache[pfad]; ok {
		return d, nil
	}
	sp := spracheFuer(pfad)
	if sp == nil {
		return nil, nil
	}
	if err := sp.laden(); err != nil {
		return nil, err
	}
	src, err := os.ReadFile(pfad)
	if err != nil {
		return nil, err
	}
	p := ts.NewParser()
	defer p.Close()
	if err := p.SetLanguage(sp.grammar); err != nil {
		return nil, err
	}
	d := &datei{pfad: pfad, src: src, sp: sp, baum: p.Parse(src, nil)}
	d.kaputt = d.baum.RootNode().HasError()
	d.symbole = extrahiereSymbole(d)
	d.importe = extrahiereImporte(d)
	cache[pfad] = d
	return d, nil
}

func extrahiereSymbole(d *datei) []symbol {
	q := d.sp.symbole
	namen := q.CaptureNames()
	cur := ts.NewQueryCursor()
	defer cur.Close()
	// Je Definitionsknoten ein Symbol; bei mehreren Treffern gewinnt der hoehere
	// Pattern-Index (spaetere Pattern verfeinern fruehere, Konvention aus Stratum).
	jeKnoten := map[[2]uint]symbol{}
	m := cur.Matches(q, d.baum.RootNode(), d.src)
	for mt := m.Next(); mt != nil; mt = m.Next() {
		var s symbol
		var def *ts.Node
		for _, c := range mt.Captures {
			n := namen[c.Index]
			switch {
			case n == "name":
				s.name = c.Node.Utf8Text(d.src)
				s.nameByte = c.Node.StartByte()
			case n == "parent":
				s.parent = c.Node.Utf8Text(d.src)
			case n == "signature": // mehrere: Parameter und Rueckgabe
				s.sig = strings.TrimSpace(s.sig + " " + strings.Join(strings.Fields(c.Node.Utf8Text(d.src)), " "))
			case strings.HasPrefix(n, "definition."):
				s.art = strings.TrimPrefix(n, "definition.")
				node := c.Node
				def = &node
			}
		}
		if def == nil || s.name == "" {
			continue
		}
		s.von, s.bis = def.StartPosition().Row+1, def.EndPosition().Row+1
		s.pattern = uint(mt.PatternIndex)
		k := [2]uint{def.StartByte(), def.EndByte()}
		if alt, ok := jeKnoten[k]; ok && alt.pattern > s.pattern {
			continue
		}
		jeKnoten[k] = s
	}
	out := make([]symbol, 0, len(jeKnoten))
	for _, s := range jeKnoten {
		if d.sp.name == "python" && s.art == "var" && s.name == strings.ToUpper(s.name) {
			s.art = "const" // Python hat kein const: GROSS_GESCHRIEBEN gilt als Konstante
		}
		out = append(out, s)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].von != out[j].von {
			return out[i].von < out[j].von
		}
		return out[i].bis > out[j].bis
	})
	return out
}

func extrahiereImporte(d *datei) []importAngabe {
	q := d.sp.importe
	namen := q.CaptureNames()
	cur := ts.NewQueryCursor()
	defer cur.Close()
	var out []importAngabe
	m := cur.Matches(q, d.baum.RootNode(), d.src)
	for mt := m.Next(); mt != nil; mt = m.Next() {
		var von, name, alias string
		erbt := false
		for _, c := range mt.Captures {
			switch namen[c.Index] {
			case "import":
				von = c.Node.Utf8Text(d.src)
			case "name":
				name = c.Node.Utf8Text(d.src)
			case "alias":
				alias = c.Node.Utf8Text(d.src)
			case "erbt":
				erbt = true
			}
		}
		if von == "" {
			continue
		}
		von = strings.Trim(von, "\"'`")
		if name != "" { // Python: from . import modul -> Modul relativ zum Paket
			if strings.Trim(von, ".") == "" {
				von += name
			} else {
				von += "." + name
			}
		}
		if alias == "" && d.sp.name == "go" {
			alias = path.Base(von) // Paketname = letztes Pfadglied (Naeherung)
		}
		out = append(out, importAngabe{ziel: von, alias: alias, erbt: erbt})
	}
	return out
}

// umgebend: innerstes Struktur-Symbol, das die Zeile enthaelt (nil: Dateiebene).
func (d *datei) umgebend(zeile uint) *symbol {
	var best *symbol
	for i := range d.symbole {
		s := &d.symbole[i]
		if !s.struktur() || zeile < s.von || zeile > s.bis {
			continue
		}
		if best == nil || s.bis-s.von < best.bis-best.von {
			best = s
		}
	}
	return best
}
