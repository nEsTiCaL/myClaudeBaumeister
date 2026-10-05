; Importe (nach Stratum queries/gdscript/imports.scm): Dateiabhaengigkeiten ueber
; res://-Pfade. Nur Literal-Pfade. @erbt: extends (Methoden sind unqualifiziert
; erreichbar), @alias: Konstante/Variable, ueber die die Datei angesprochen wird.
(extends_statement (string) @import @erbt)
((call (identifier) @_fn (arguments . (string) @import)) (#any-of? @_fn "preload" "load"))
((const_statement name: (name) @alias
   value: (call (identifier) @_fn (arguments . (string) @import))) (#any-of? @_fn "preload" "load"))
((variable_statement name: (name) @alias
   value: (call (identifier) @_fn (arguments . (string) @import))) (#any-of? @_fn "preload" "load"))
