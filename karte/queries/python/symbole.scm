; Symbole fuer Python (nach Stratum queries/python/symbols.scm, angepasst an
; tree-sitter-python 0.25: Zuweisungen stecken in expression_statement).
; Capture-Konvention: @name Bezeichner, @definition.<art> Definitionsknoten,
; @parent umschliessende Klasse, @signature Parameter/Basisklassen.
; Spaetere Pattern verfeinern fruehere (gleicher Knoten: hoeherer Index gewinnt).

(class_definition
  name: (identifier) @name
  superclasses: (argument_list)? @signature) @definition.class

(function_definition
  name: (identifier) @name
  parameters: (parameters) @signature
  return_type: (_)? @signature) @definition.function

; Methode = Funktion direkt (oder dekoriert) im Klassenrumpf
(class_definition
  name: (identifier) @parent
  body: (block
    [(function_definition
       name: (identifier) @name
       parameters: (parameters) @signature
       return_type: (_)? @signature) @definition.method
     (decorated_definition
       (function_definition
         name: (identifier) @name
         parameters: (parameters) @signature
         return_type: (_)? @signature) @definition.method)]))

(module
  (expression_statement (assignment
    left: (identifier) @name)) @definition.var)

(class_definition
  name: (identifier) @parent
  body: (block
    (expression_statement (assignment
      left: (identifier) @name)) @definition.var))
