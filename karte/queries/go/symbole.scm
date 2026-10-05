; Symbole fuer Go. Methoden tragen den Receiver-Typ als @parent.
; Spaetere Pattern verfeinern fruehere: struct/interface vor allgemeinem type.
(function_declaration
  name: (identifier) @name
  parameters: (parameter_list) @signature
  result: (_)? @signature) @definition.function

(method_declaration
  receiver: (parameter_list
    (parameter_declaration
      type: [(type_identifier) @parent
             (pointer_type (type_identifier) @parent)
             (generic_type type: (type_identifier) @parent)
             (pointer_type (generic_type type: (type_identifier) @parent))]))
  name: (field_identifier) @name
  parameters: (parameter_list) @signature
  result: (_)? @signature) @definition.method

(type_declaration (type_spec name: (type_identifier) @name type: (_) @signature) @definition.type)
(type_declaration (type_spec name: (type_identifier) @name type: (struct_type)) @definition.struct)
(type_declaration (type_spec name: (type_identifier) @name type: (interface_type)) @definition.interface)

(source_file (var_declaration (var_spec name: (identifier) @name) @definition.var))
(source_file (var_declaration (var_spec_list (var_spec name: (identifier) @name) @definition.var)))
(source_file (const_declaration (const_spec name: (identifier) @name) @definition.const))
