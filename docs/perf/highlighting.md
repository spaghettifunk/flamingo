# Syntax Highlighting Optimization

## Problems

- Full-file highlighting per frame
- Tree-sitter work on UI thread
- No caching of results

## Target Model

### 1. Viewport-Based Highlighting

Only compute for:

```text
visible_lines ± margin (e.g. 20 lines)
```
