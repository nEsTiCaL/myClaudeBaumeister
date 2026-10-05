package main

import (
	"embed"
	"fmt"
	"path/filepath"
	"unsafe"

	ts "github.com/tree-sitter/go-tree-sitter"
	tsgo "github.com/tree-sitter/tree-sitter-go/bindings/go"
	py "github.com/tree-sitter/tree-sitter-python/bindings/go"

	"karte/grammatik/gdscript"
)

//go:embed queries
var queries embed.FS

// sprache: Grammatik plus die Knotenarten, die der sprachunabhaengige Kern zum
// Einordnen von Treffern braucht. Alles Weitere steckt in queries/<name>/*.scm.
type sprache struct {
	name     string
	grammar  *ts.Language
	aufruf   map[string]bool // Aufrufknoten: Callee ist Feld "function" oder erstes Kind
	member   map[string]bool // a.b-Knoten: Treffer auf b steigt fuer die Aufruf-Pruefung auf
	text     map[string]bool // String-artige Knoten: Treffer darin ist dynamisch
	einschub map[string]bool // Code innerhalb eines Strings (f-String-Interpolation)

	symbole, importe *ts.Query
}

func menge(s ...string) map[string]bool {
	m := map[string]bool{}
	for _, x := range s {
		m[x] = true
	}
	return m
}

var sprachen = map[string]*sprache{
	".go": {
		name: "go", grammar: ts.NewLanguage(tsgo.Language()),
		aufruf: menge("call_expression"),
		member: menge("selector_expression", "qualified_type"),
		text:   menge("interpreted_string_literal", "raw_string_literal"),
	},
	".py": {
		name: "python", grammar: ts.NewLanguage(py.Language()),
		aufruf:   menge("call"),
		member:   menge("attribute"),
		text:     menge("string"),
		einschub: menge("interpolation"),
	},
	".gd": {
		name: "gdscript", grammar: ts.NewLanguage(unsafe.Pointer(gdscript.Language())),
		aufruf: menge("call", "attribute_call"),
		member: menge("attribute"),
		// $Knoten/Pfad und %Unique sind Szenenpfade: Namen darin sind Text.
		text: menge("string", "string_name", "node_path", "get_node"),
	},
}

func spracheFuer(pfad string) *sprache {
	return sprachen[filepath.Ext(pfad)]
}

func (s *sprache) query(art string) (*ts.Query, error) {
	scm, err := queries.ReadFile("queries/" + s.name + "/" + art + ".scm")
	if err != nil {
		return nil, err
	}
	q, qerr := ts.NewQuery(s.grammar, string(scm))
	if qerr != nil {
		return nil, fmt.Errorf("Query %s/%s.scm: %v", s.name, art, qerr)
	}
	return q, nil
}

// laden kompiliert die Queries einer Sprache beim ersten Gebrauch.
func (s *sprache) laden() error {
	if s.symbole != nil {
		return nil
	}
	var err error
	if s.symbole, err = s.query("symbole"); err != nil {
		return err
	}
	s.importe, err = s.query("importe")
	return err
}
