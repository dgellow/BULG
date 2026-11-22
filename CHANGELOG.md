# Changelog

Until 1.0 the language edition is the minor version. Each release lists the language,
the emitters and the API separately.

## 0.1.0 (unreleased)

### Language
- Tokens: names, keywords (Glint's `import alias uniform block param spec extern program
  template link`, GLSL's statements and qualifiers), integer literals (decimal, hex, `u`),
  float literals (`1.`, `.5`, `1e3`, `f`), strings (one line, no escapes), every GLSL
  operator. `while`, `do`, `switch` and `precision` are keywords so that their use gets a
  diagnostic of its own.
- No preprocessor: `#define` and the like give E0001 with a hint.
- Grammar: `import "path" [: names];`, `alias NAME = expr;`, `uniform block NAME { ... };`,
  `struct`, declarations with `const uniform in out flat param spec` and
  `layout(location = n)`, several names per declaration, arrays (`vec4 a[8]`, `float[9]`),
  `{ key(args), key }` metadata, functions, prototypes, `extern` prototypes, and
  `program [template] NAME [: PARENT] { vertex "f"; fragment "f"; link "f"; spec N = e; }`.
- Statements: blocks, declarations, expressions, `if`/`else`, `for`, `return`, `break`,
  `continue`, `discard`. `while`, `do`, `switch` (E0101) and `precision` (E0102) are named.
- Expressions: GLSL's operators and precedence, `?:`, assignment operators, calls and
  constructors (`float[9](...)`), indexing, fields and swizzles, `++`/`--`. No comma
  operator.
- Glint's own keywords cannot be names; using one as a name says so.

### API
- `parse` (with `Parser`): a whole tree even when there are errors; recovery at the end of
  the statement or item. Nesting bounded by `Limits.nesting` (E0103).
- `Ast`: a flat node array, lists in `extra`, every node tied to a token, literals as
  written. `Ast.print` writes canonical text that parses back to the same text and the
  same tree; `printWith(.{ .all_parens = true })` prints the tree's shape.
- Diagnostic codes E0100-E0107 for parsing.
- The `glint` command: `parse` and `print [--shape]`.
- `Source` (line and column of a span), `Diagnostic` (stable codes E0001-E0007, a list with
  a limit, rendering with a caret), `Limits`, `Token`, `Lexer.tokenize`.

### Emitters
- None yet.
