; Importe: @import = Modulangabe (dotted oder relativ mit Punkten),
; @name = bei "from . import x" der importierte Name (kann ein Modul sein).
(import_statement name: (dotted_name) @import)
(import_statement name: (aliased_import name: (dotted_name) @import))
(import_from_statement module_name: (dotted_name) @import)
(import_from_statement module_name: (relative_import) @import)
(import_from_statement
  module_name: (relative_import) @import
  name: (dotted_name) @name)
(import_from_statement
  module_name: (relative_import) @import
  name: (aliased_import name: (dotted_name) @name))
