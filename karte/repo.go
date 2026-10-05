package main

import (
	"bufio"
	"bytes"
	"os"
	"os/exec"
	"path"
	"sort"
	"strings"
)

// repo: versionierte und unversionierte Dateien (git ls-files) und der
// Importgraph zwischen ihnen.
// Alle Pfade relativ zur Repo-Wurzel; main wechselt dorthin.
type repo struct {
	dateien []string
	gibt    map[string]bool
	goMods  map[string]string // Modulpfad -> Verzeichnis (go.mod)
	godot   []string          // Verzeichnisse mit project.godot (res://-Wurzeln)

	importiert    map[string][]string // Datei -> Dateien, die sie importiert
	importiertVon map[string][]string // Datei -> Dateien, die sie importieren
}

// gitDateien: versionierte und unversionierte (nicht ignorierte) Dateien.
func gitDateien() ([]string, error) {
	out, err := exec.Command("git", "ls-files", "-z", "--cached", "--others", "--exclude-standard").Output()
	if err != nil {
		return nil, err
	}
	gesehen := map[string]bool{}
	var d []string
	for _, f := range bytes.Split(out, []byte{0}) {
		if len(f) == 0 || gesehen[string(f)] {
			continue
		}
		gesehen[string(f)] = true
		d = append(d, string(f))
	}
	sort.Strings(d)
	return d, nil
}

func ladeRepo() (*repo, error) {
	r := &repo{gibt: map[string]bool{}, goMods: map[string]string{}}
	var err error
	if r.dateien, err = gitDateien(); err != nil {
		return nil, err
	}
	for _, f := range r.dateien {
		r.gibt[f] = true
		switch path.Base(f) {
		case "go.mod":
			if m := goModul(f); m != "" {
				r.goMods[m] = path.Dir(f)
			}
		case "project.godot":
			r.godot = append(r.godot, path.Dir(f))
		}
	}
	return r, nil
}

func goModul(f string) string {
	fh, err := os.Open(f)
	if err != nil {
		return ""
	}
	defer fh.Close()
	sc := bufio.NewScanner(fh)
	for sc.Scan() {
		if m, ok := strings.CutPrefix(strings.TrimSpace(sc.Text()), "module "); ok {
			return strings.Trim(strings.TrimSpace(m), `"`)
		}
	}
	return ""
}

// quellen: unterstuetzte Dateien unter den Pfaden (leer: alle).
func (r *repo) quellen(pfade []string) []string {
	var out []string
	for _, f := range r.dateien {
		if spracheFuer(f) == nil {
			continue
		}
		if len(pfade) == 0 {
			out = append(out, f)
			continue
		}
		for _, p := range pfade {
			if p == "." || f == p || strings.HasPrefix(f, strings.TrimSuffix(p, "/")+"/") {
				out = append(out, f)
				break
			}
		}
	}
	return out
}

// graph liest alle Quellen und loest ihre Importe zu Dateien auf.
func (r *repo) graph() error {
	if r.importiert != nil {
		return nil
	}
	r.importiert, r.importiertVon = map[string][]string{}, map[string][]string{}
	for _, f := range r.quellen(nil) {
		d, err := lies(f)
		if err != nil || d == nil {
			continue
		}
		ziele := map[string]bool{}
		for _, imp := range d.importe {
			for _, z := range r.aufloesen(d, imp.ziel) {
				if z != f {
					ziele[z] = true
				}
			}
		}
		for z := range ziele {
			r.importiert[f] = append(r.importiert[f], z)
			r.importiertVon[z] = append(r.importiertVon[z], f)
		}
	}
	for _, m := range []map[string][]string{r.importiert, r.importiertVon} {
		for k := range m {
			sort.Strings(m[k])
		}
	}
	return nil
}

// aufloesen: Importangabe -> versionierte Dateien (leer: extern/unbekannt).
// Go importiert Pakete: Ziel sind alle Nicht-Test-Dateien des Verzeichnisses.
func (r *repo) aufloesen(d *datei, imp string) []string {
	switch d.sp.name {
	case "gdscript":
		rest, ok := strings.CutPrefix(imp, "res://")
		if !ok {
			return nil
		}
		for _, w := range r.godot { // naechste project.godot oberhalb der Datei
			if w == "." || strings.HasPrefix(d.pfad, w+"/") {
				if z := path.Join(w, rest); r.gibt[z] {
					return []string{z}
				}
			}
		}
	case "go":
		for m, dir := range r.goMods {
			if imp == m || strings.HasPrefix(imp, m+"/") {
				return r.paket(path.Join(dir, strings.TrimPrefix(imp, m)))
			}
		}
	case "python":
		punkte := len(imp) - len(strings.TrimLeft(imp, "."))
		teile := strings.ReplaceAll(strings.TrimLeft(imp, "."), ".", "/")
		var basen []string
		if punkte > 0 { // relativ zum Paket der Datei
			b := path.Dir(d.pfad)
			for i := 1; i < punkte; i++ {
				b = path.Dir(b)
			}
			basen = []string{b}
		} else { // absolut: Repo-Wurzel und jedes Verzeichnis oberhalb der Datei
			for b := path.Dir(d.pfad); ; b = path.Dir(b) {
				basen = append(basen, b)
				if b == "." {
					break
				}
			}
		}
		for _, b := range basen {
			// "a.b.f": Modul a/b.py, wenn f nur ein Name darin ist
			for t := teile; t != "" && t != "."; t = path.Dir(t) {
				for _, z := range []string{path.Join(b, t+".py"), path.Join(b, t, "__init__.py")} {
					if r.gibt[z] {
						return []string{z}
					}
				}
			}
		}
	}
	return nil
}

func (r *repo) paket(dir string) []string {
	var out []string
	for _, f := range r.dateien {
		if path.Dir(f) == dir && strings.HasSuffix(f, ".go") && !strings.HasSuffix(f, "_test.go") {
			out = append(out, f)
		}
	}
	return out
}
