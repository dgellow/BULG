# Changelog

Until 1.0 the language edition is the minor version. Each release lists the language,
the emitters and the API separately.

## 0.1.0 (unreleased)

### Language
- Tokens: names, keywords (Glint's `import alias uniform block param spec extern program
  template link`, GLSL's statements and qualifiers), integer literals (decimal, hex, `u`),
  float literals (`1.`, `.5`, `1e3`, `f`), strings (one line, no escapes), every GLSL
  operator. `while`, `do`, `switch` and `precision` are keywords so that their use gets a
  diagnostic of its own later.
- No preprocessor: `#define` and the like give E0001 with a hint.

### API
- `Source` (line and column of a span), `Diagnostic` (stable codes E0001-E0007, a list with
  a limit, rendering with a caret), `Limits`, `Token`, `Lexer.tokenize`.

### Emitters
- None yet.
