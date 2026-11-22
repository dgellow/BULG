# Targets

What each emitter writes, and the rules every target keeps. The golden texts in
`tests/golden/*/expected` show the output exactly; `zig build update-golden` records it
again after a deliberate change, and the diff is the review.

## The rules for every target

- **The text says what the source says.** Inside a function nothing is folded, inlined,
  reassociated or reordered. Literals are printed as written. Parentheses are added only
  where precedence needs them. A driver therefore compiles the program the author wrote,
  and the GL output draws exactly what the hand-written GLSL drew. (A consumer can prove
  it: render reference frames with its own GLSL, then with Glint's text in its place,
  and compare the hashes.)
- **Specialisation is the one transformation.**
  - A spec constant takes the variant's value.
  - An `if` or `?:` whose condition depends only on spec constants and constants keeps
    the branch taken, in its own scope. That is what `#ifdef` did.
  - A spec constant still used elsewhere is declared as a constant with the variant's
    value.
- **Only what `main` reaches is emitted:** functions, globals, structs, and uniform
  blocks whole (a block keeps its layout).
- **Order:**
  - modules in link order, the imported ones first;
  - in each module, the source's order;
  - a declaration moves only as far as a dependency needs.
- **Names stay as written.** When two modules of one stage declare one name, the later in
  the text becomes `name_2` (functions of one name with different parameters are
  overloads and keep it).
- **Aliases** are printed where they are used, as their expression.
- **No finite-maths assumption:** NaN compares false, and no emitter may assume
  otherwise.
- **The line map** takes each emitted line back to its source line, and `glsl.mapLog`
  rewrites a driver's log (`0:LINE` from Mesa and ANGLE, `0(LINE)` from others) into
  `path:line`.

## GLSL ES 3.00 (`es300`)

- The header is `#version 300 es` and `highp` precision for floats, ints and `sampler2D`.
  Precision is the target's business, not the source's.
- `half` and its vectors and matrices are `float` in v0. Real 16-bit lowering comes later.
- Checked by a real driver: `zig build check-gpu` compiles and links the golden texts in
  Chromium's WebGL 2 (ANGLE); `tests/webgl_es300.mjs` does the same for any directory of
  emitted texts.

## GLSL 3.30 (`glsl330`)

- The header is `#version 330 core`. The rest is the ES 3.00 text: Glint's v0 is inside
  what both dialects accept the same way.

## WGSL and MSL

Not yet. They come after the interpreter, WGSL first. Their coordinate convention (GL's
y-up and `gl_FragCoord` origin, which the language keeps) is decided at the WGSL
milestone.
