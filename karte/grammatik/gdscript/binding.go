// Paket gdscript bindet die tree-sitter-Grammatik fuer GDScript ein.
// Herkunft und Aktualisierung: HERKUNFT.md.
package gdscript

// #cgo CFLAGS: -std=c11 -fPIC
// #include "src/parser.c"
// #include "src/scanner.c"
import "C"

import "unsafe"

// Language liefert die Grammatik (fuer tree_sitter.NewLanguage).
func Language() unsafe.Pointer { return unsafe.Pointer(C.tree_sitter_gdscript()) }
