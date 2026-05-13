(atx_heading
  (inline) @keyword)

(setext_heading
  (paragraph) @keyword)

[
  (atx_h1_marker)
  (atx_h2_marker)
  (atx_h3_marker)
  (atx_h4_marker)
  (atx_h5_marker)
  (atx_h6_marker)
  (setext_h1_underline)
  (setext_h2_underline)
  (fenced_code_block_delimiter)
  (list_marker_plus)
  (list_marker_minus)
  (list_marker_star)
  (list_marker_dot)
  (list_marker_parenthesis)
  (thematic_break)
] @punctuation

[
  (indented_code_block)
  (fenced_code_block)
  (code_fence_content)
] @string

[
  (block_continuation)
  (block_quote_marker)
] @comment

(link_destination) @function

(link_label) @function

(backslash_escape) @string
