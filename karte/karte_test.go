package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// testRepo: testdata/projekt als frisches git-Repo, Arbeitsverzeichnis dort.
func testRepo(t *testing.T) *repo {
	t.Helper()
	ziel := t.TempDir()
	if err := os.CopyFS(ziel, os.DirFS("testdata/projekt")); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{{"init", "-q"}, {"add", "-A"}} {
		if out, err := exec.Command("git", append([]string{"-C", ziel}, args...)...).CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	t.Chdir(ziel)
	cache = map[string]*datei{}
	r, err := ladeRepo()
	if err != nil {
		t.Fatal(err)
	}
	if err := r.graph(); err != nil {
		t.Fatal(err)
	}
	return r
}

func symbolNamen(t *testing.T, f string) []string {
	t.Helper()
	d, err := lies(f)
	if err != nil || d == nil {
		t.Fatalf("%s: %v", f, err)
	}
	var out []string
	for _, s := range d.symbole {
		out = append(out, s.art+" "+s.voll()+sigTeil(s.sig))
	}
	return out
}

func TestSymbole(t *testing.T) {
	testRepo(t)
	for f, want := range map[string][]string{
		"pkg/a/a.go": {"struct Arena", "function Parse(raw []byte) (*Arena, error)", "method Arena.Run(n int)"},
		"client/main.gd": {"function _ready()", "function _open()", "const Hud"},
		"tools/helfer.py": {"const GRENZE", "function h(x)", "class Werk", "method Werk.h(self)"},
	} {
		got := symbolNamen(t, f)
		for _, w := range want {
			if !slices.Contains(got, w) {
				t.Errorf("%s: %q fehlt in %q", f, w, got)
			}
		}
	}
}

func TestImporte(t *testing.T) {
	r := testRepo(t)
	for f, want := range map[string][]string{
		"pkg/b/b.go":     {"pkg/a/a.go"},
		"client/main.gd": {"client/hud.gd"},
		"client/kind.gd": {"client/main.gd"},
		"tools/p.py":     {"tools/helfer.py"},
	} {
		if got := r.importiert[f]; !slices.Equal(got, want) {
			t.Errorf("%s importiert %q, erwartet %q", f, got, want)
		}
	}
}

// zeilen: "klasse pfad:zeile[?]" je Treffer, ausgeblendete als "fremd(grund) pfad:zeile".
func zeilen(e *ergebnis) []string {
	var out []string
	for _, t := range e.rest {
		h := ""
		if t.hinweis {
			h = "?"
		}
		out = append(out, t.klasse+" "+t.pfad+":"+itoa(t.zeile)+h)
	}
	for g, ts := range e.fremd {
		for _, t := range ts {
			out = append(out, "fremd("+g+") "+t.pfad+":"+itoa(t.zeile))
		}
	}
	return out
}

func TestLeser(t *testing.T) {
	r := testRepo(t)
	faelle := []struct {
		ziel       string
		defs       int
		hat, nicht []string
	}{
		{"a.Parse", 1,
			[]string{"Aufruf pkg/b/b.go:15", "Prosa pkg/b/b.go:18", "Kommentar pkg/a/a.go:8"},
			[]string{"Aufruf pkg/b/b.go:14"}},
		{"Parse", 1,
			[]string{"fremd(anderes Paket/Datei: flag.Parse) pkg/b/b.go:14"}, nil},
		{"Arena", 1,
			[]string{"Referenz pkg/b/b.go:10", "Referenz pkg/a/a.go:9",
				"fremd(gleichnamige Deklaration (Feld, Parameter, lokal)) pkg/b/b.go:10",
				"fremd(Feld/Methode eines Werts) pkg/b/b.go:17"}, nil},
		{"Arena.Run", 1, []string{"Aufruf pkg/b/b.go:16?", "Aufruf pkg/a/a.go:14?"}, nil},
		{"_open", 1,
			[]string{"Aufruf client/main.gd:7", "Aufruf client/kind.gd:4", "Text client/main.gd:6",
				"Andere Datei client/main.tscn:1", "Kommentar client/main.gd:11"}, nil},
		{"hud.gd:text", 1,
			[]string{"Aufruf client/main.gd:5", "fremd(Feld/Methode eines Werts) client/main.gd:8",
				"Prosa client/main.gd:9"},
			[]string{"Text client/main.gd:9"}},
		{"helfer.h", 1, []string{"Aufruf tools/p.py:3?", "Aufruf tools/helfer.py:9", "Kommentar tools/helfer.py:4"}, nil},
		{"Werk.h", 1, nil, nil},
	}
	for _, f := range faelle {
		e, err := r.suchen(parseZiel(f.ziel))
		if err != nil {
			t.Fatal(err)
		}
		if len(e.defs) != f.defs {
			t.Errorf("%s: %d Definitionen, erwartet %d: %v", f.ziel, len(e.defs), f.defs, e.defs)
		}
		got := zeilen(e)
		for _, w := range f.hat {
			if !slices.Contains(got, w) {
				t.Errorf("%s: %q fehlt in\n  %s", f.ziel, w, strings.Join(got, "\n  "))
			}
		}
		for _, w := range f.nicht {
			if slices.Contains(got, w) {
				t.Errorf("%s: %q sollte fehlen", f.ziel, w)
			}
		}
	}
}

// TestIndex: Format, Argumentreihenfolge, "-", Ueberspringen, Doppelte, Budget.
func TestIndex(t *testing.T) {
	r := testRepo(t)
	a := "pkg/a/a.go: Arena 4-6, Parse 9-11, Arena.Run 13-15\n"
	h := "tools/helfer.py: h 3-5, Werk 7-9, Werk.h 8-9\n"
	faelle := []struct {
		name  string
		pfade []string
		want  string
	}{
		{"reihenfolge", []string{"tools/p.py", "tools/helfer.py", "pkg/a/a.go"}, "tools/p.py: -\n" + h + a},
		{"doppelte und uebersprungene",
			[]string{"pkg/a/a.go", "pkg/a/a.go", "pkg", "fehlt.go", "client/main.tscn", "client/main.gd"},
			a + "client/main.gd: _ready 4-9, _open 12-13\n"},
		{"nichts verwertbar", []string{"pkg", "fehlt.go", "client/main.tscn"}, ""},
	}
	for _, f := range faelle {
		if got := index(r, f.pfade, stdIndex); got != f.want {
			t.Errorf("%s:\n got %q\nwant %q", f.name, got, f.want)
		}
	}
	// Budget: erste Zeile ganz, zweite bis zum letzten ganzen Eintrag gekuerzt.
	gekuerzt := "tools/helfer.py: h 3-5 …(+2)\n"
	budget := len(a + gekuerzt)
	if got := index(r, []string{"pkg/a/a.go", "tools/helfer.py"}, budget); got != a+gekuerzt {
		t.Errorf("budget kuerzen:\n got %q\nwant %q", got, a+gekuerzt)
	}
	// Weitere Dateien danach: nur die letzte Zeile nennt sie (zaehlt nicht mit).
	rest := []string{"pkg/a/a.go", "tools/helfer.py", "tools/p.py", "client/kind.gd"}
	want := a + gekuerzt + "… nicht gezeigt: tools/p.py, client/kind.gd\n"
	if got := index(r, rest, budget); got != want {
		t.Errorf("budget rest:\n got %q\nwant %q", got, want)
	}
	// Passt auch kein Eintrag mehr, entfaellt die Zeile ganz.
	knapp := len(a) + 10
	want = a + "… nicht gezeigt: tools/helfer.py\n"
	if got := index(r, []string{"pkg/a/a.go", "tools/helfer.py"}, knapp); got != want {
		t.Errorf("budget knapp:\n got %q\nwant %q", got, want)
	}
}

// TestIndexUnversioniert: unversionierte Datei erscheint (git ls-files --others).
func TestIndexUnversioniert(t *testing.T) {
	testRepo(t)
	if err := os.MkdirAll("pkg/c", 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile("pkg/c/c.go", []byte("package c\n\ntype Neu struct {\n\tX int\n}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	cache = map[string]*datei{}
	r, err := ladeRepo()
	if err != nil {
		t.Fatal(err)
	}
	want := "pkg/c/c.go: Neu 3-5\n"
	if got := index(r, []string{"pkg/c/c.go"}, stdIndex); got != want {
		t.Errorf("unversionierte Datei:\n got %q\nwant %q", got, want)
	}
	// Auch verwendung findet die Definition dort (git grep --untracked).
	if err := r.graph(); err != nil {
		t.Fatal(err)
	}
	text, gefunden, err := verwendung(r, parseZiel("Neu"), stdVerwendung)
	if err != nil {
		t.Fatal(err)
	}
	if want := "Definition Neu: pkg/c/c.go:3-5 struct Neu\n"; !gefunden || text != want {
		t.Errorf("unversionierte Datei in verwendung: gefunden=%v, %q", gefunden, text)
	}
}

// TestVerwendung: Definition, Gruppierung mit Bereich, Dateiebene, "?",
// Verhalten ohne Definition (Exit 2 ohne Ausgabe).
func TestVerwendung(t *testing.T) {
	r := testRepo(t)
	faelle := []struct {
		ziel string
		want string
	}{
		{"Arena.Run",
			"Definition Run: pkg/a/a.go:13-15 method Arena.Run(n int)\n" +
				"Aufrufe: pkg/a/a.go Arena.Run 13-15 (14?), pkg/b/b.go Use 13-19 (16?)\n"},
		{"helfer.h",
			"Definition h: tools/helfer.py:3-5 function h(x)\n" +
				"Aufrufe: tools/helfer.py Werk.h 8-9 (9), tools/p.py Dateiebene (3?)\n" +
				"Sonst: Kommentar 1\n"},
		{"neu.hilfe",
			"Definition hilfe: neu/paar.py:1-2 function hilfe(z)\n" +
				"Aufrufe: neu/paar.py doppelt 5-7 (6, 7)\n"},
		{"_open", // Text, andere Datei, Kommentar, Dateiebene-los
			"Definition _open: client/main.gd:12-13 function _open()\n" +
				"Aufrufe: client/kind.gd f 3-4 (4), client/main.gd _ready 4-9 (7)\n" +
				"Text (dynamisch): client/main.gd:6\n" +
				"Sonst: Kommentar 1, Andere Datei 1\n"},
		{"Arena", // Referenzen, mehrere Fundstellen je Gruppe, ausgeblendete
			"Definition Arena: pkg/a/a.go:4-6 struct Arena\n" +
				"Referenzen: pkg/a/a.go Parse 9-11 (9, 10), pkg/a/a.go Arena.Run 13-15 (13), pkg/b/b.go Opt 9-11 (10)\n" +
				"Sonst: Kommentar 2, ausgeblendet 2\n"},
		{"h", // zwei Definitionen
			"Definition h: tools/helfer.py:3-5 function h(x)\n" +
				"Definition h: tools/helfer.py:8-9 method Werk.h(self)\n" +
				"Achtung: 2 Definitionen passen\n" +
				"Aufrufe: tools/helfer.py Werk.h 8-9 (9), tools/p.py Dateiebene (3?)\n" +
				"Sonst: Kommentar 1\n"},
	}
	for _, f := range faelle {
		got, gefunden, err := verwendung(r, parseZiel(f.ziel), stdVerwendung)
		if err != nil {
			t.Fatalf("%s: %v", f.ziel, err)
		}
		if !gefunden {
			t.Errorf("%s: keine Definition gefunden", f.ziel)
		}
		if got != f.want {
			t.Errorf("%s:\n got %q\nwant %q", f.ziel, got, f.want)
		}
	}
	// Knappes Budget: Definition bleibt stehen, Gruppen entfallen.
	got, _, err := verwendung(r, parseZiel("neu.hilfe"), 10)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(got, "Definition hilfe:") || strings.Contains(got, "Aufrufe") {
		t.Errorf("knappes Budget: %q", got)
	}
	// Ohne Definition im Repo: keine Ausgabe, gefunden false.
	got, gefunden, err := verwendung(r, parseZiel("gibtesnicht"), stdVerwendung)
	if err != nil {
		t.Fatal(err)
	}
	if gefunden || got != "" {
		t.Errorf("ohne Definition: gefunden=%v, Ausgabe %q", gefunden, got)
	}
}

func TestQueriesKompilieren(t *testing.T) {
	for ext, sp := range sprachen {
		if err := sp.laden(); err != nil {
			t.Errorf("%s: %v", ext, err)
		}
	}
	if _, err := os.Stat(filepath.Join("grammatik", "gdscript", "HERKUNFT.md")); err != nil {
		t.Error("grammatik/gdscript/HERKUNFT.md fehlt")
	}
}
