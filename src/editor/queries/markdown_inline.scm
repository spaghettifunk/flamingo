[
  (code_span)
  (link_title)
] @string

[
  (emphasis_delimiter)
  (code_span_delimiter)
] @punctuation

(emphasis) @type

(strong_emphasis) @constant

[
  (link_destination)
  (uri_autolink)
  (email_autolink)
] @function

[
  (link_label)
  (link_text)
  (image_description)
] @function

[
  (backslash_escape)
  (hard_line_break)
] @string

(html_tag) @string

(image
  [
    "!"
    "["
    "]"
    "("
    ")"
  ] @punctuation)

(inline_link
  [
    "["
    "]"
    "("
    ")"
  ] @punctuation)

(shortcut_link
  [
    "["
    "]"
  ] @punctuation)
