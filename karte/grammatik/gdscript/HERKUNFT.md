# tree-sitter-gdscript (eingebettet)

Quelle: https://github.com/PrestonKnopp/tree-sitter-gdscript (MIT, siehe LICENSE)
Stand:  8ecb27ed77c09edd7cca123bbecebd44930b765c (2026-09-18)

Übernommen: `src/parser.c`, `src/scanner.c`, `src/tree_sitter/` unverändert.

Warum hier statt als Go-Modul: Das Go-Binding upstream (`bindings/go`) deklariert
den Modulpfad `github.com/tree-sitter/tree-sitter-gdscript`, liegt aber unter
`github.com/PrestonKnopp/...`. `go get` lehnt es deshalb ab. Außerdem bindet es
`../../src/parser.c` ein, also Dateien außerhalb des Moduls. `binding.go` hier
ist der Ersatz und bindet die C-Quellen aus `src/` ein.

Aktualisieren: `bash grammatik/aktualisieren.sh [commit]` (ohne Angabe: neuester
Stand). Danach `go test ./...` laufen lassen. Geänderte Knotennamen zeigen sich
dort als Query-Fehler. Den Stand oben trägt das Skript selbst nach.
