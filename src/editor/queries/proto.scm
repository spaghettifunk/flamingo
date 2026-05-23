(package
  (full_ident
    (identifier) @property))

(extend
  (full_ident
    (identifier) @type))

(constant
  (full_ident
    (identifier) @constant))

(field
  (identifier) @property)

(map_field
  (identifier) @property)

(oneof
  (identifier) @type)

(oneof_field
  (identifier) @property)

(field_option
  (identifier) @property)

(enum_value_option
  (identifier) @property)

(block_lit
  (identifier) @property)

(option
  (full_ident
    (identifier) @property))

[
  "option"
  "syntax"
  "edition"
  "package"
  "import"
  "reserved"
  "to"
  "max"
  "enum"
  "extend"
  "extensions"
  "group"
  "message"
  "map"
  "oneof"
  "service"
  "rpc"
  "returns"
  "export"
  "local"
  "optional"
  "repeated"
  "required"
  "stream"
  "weak"
  "public"
] @keyword

[
  (key_type)
  (type)
] @type

[
  (message_name)
  (enum_name)
  (service_name)
  (message_or_enum_type)
] @type

(rpc_name) @function

(enum_field
  (identifier) @constant)

(string) @string

(import
  path: (string) @string)

[
  "\"proto3\""
  "\"proto2\""
] @string

(escape_sequence) @string

(int_lit) @number

(float_lit) @number

[
  (true)
  (false)
] @constant

(comment) @comment

[
  "("
  ")"
  "["
  "]"
  "{"
  "}"
  "<"
  ">"
] @punctuation

[
  ";"
  ","
  "."
  ":"
] @punctuation

[
  "="
  "-"
  "+"
] @operator
