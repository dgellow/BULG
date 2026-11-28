# Targets

What each emitter writes, and the rules every target keeps. The golden texts in
`tests/golden/*/expected` show the output exactly; `zig build update-golden` records it
again after a deliberate change, and the diff is the review.

## The rules for every target

- **The text says what the source says.** Inside a function nothing is folded, inlined,
  reassociated or reordered. Literals are printed as written. Parentheses are added only
  where precedence needs them. A driver therefore compiles the program the author wrote,
  and the GL output draws exactly what the hand-written GLSL drew. (A consumer can prove
  it: render reference frames with its own GLSL, then with BULG's text in its place,
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
- **Loose uniforms are one block.** A program's uniforms and params that are not samplers
  and not in a block go into one std140 block, `bulg_Params`: both stages' members, in
  the order the texts declare them (vertex first), the same block in every stage that
  reads any of them. A host fills one struct (the generated `Params`) and uploads it once
  per draw: no uniform is set by name.
- **No finite-maths assumption:** NaN compares false, and no emitter may assume
  otherwise.
- **The line map** takes each emitted line back to its source line, and `glsl.mapLog`
  rewrites a driver's log (`0:LINE` from Mesa and ANGLE, `0(LINE)` from others) into
  `path:line`.

## GLSL ES 3.00 (`es300`)

- The header is `#version 300 es` and `highp` precision for floats, ints and `sampler2D`.
  Precision is the target's business, not the source's.
- `half` and its vectors and matrices are `float` in v0. Real 16-bit lowering comes later.
- `bulg_Params` is `layout(std140) uniform bulg_Params { ... };`, its members read by
  their names. ES 3.00 has no binding qualifier: the host binds it with
  `glUniformBlockBinding` (Kykeon: 1, after Frame at 0), and gives each sampler its unit
  with `glUniform1i` once, after linking.
- Checked by a real driver: `zig build check-gpu` compiles and links the golden texts in
  Chromium's WebGL 2 (ANGLE); `tests/webgl_es300.mjs` does the same for any directory of
  emitted texts.

## GLSL 3.30 (`glsl330`)

- The header is `#version 330 core`. The rest is the ES 3.00 text: BULG's v0 is inside
  what both dialects accept the same way.

## MSL (`msl`)

The body is the GLSL text with Metal's spellings. Every rule above holds.

- **Types:** `float3`, `float3x3`, `int2`, `bool4` and so on; arrays are `array<T, N>`.
  `half` is `float` in v0, as on GL.
- **Literals:** each float literal gets an `f`, since C++ reads an unsuffixed one as a double.
- **Built-ins:** most keep their name. A few are Metal's under another name: `atan2`,
  `rsqrt`, `dfdx`, `dfdy`, `rint`, `select` for `mix` with a bool vector, `as_type` for the
  bit casts, and the pack functions. The rest are prelude functions of the GLSL name,
  written only when the text uses them:
  - `mod`, `radians`, `degrees`;
  - `lessThan` and its family;
  - `matrixCompMult`, `outerProduct`, `inverse`;
  - the texture functions on `sampler2D`, which is a struct of a `texture2d<float>` and a
    `sampler`. In a vertex stage `texture` reads level 0.
  Where GLSL mixes a scalar with vectors (`min(v, 0.)`, `mix(a, b, t)`), the scalar is
  made the vector. GLSL constructors that Metal lacks are spelt out:
  - a vector cut from a longer one becomes a swizzle;
  - a matrix from scalars is built from its columns;
  - a matrix from a scalar or from another size goes through a prelude function.
- **The stage is one struct, `bulg_Stage`.** Metal has no mutable program-scope variables,
  and a function sees only what it is given. So the stage's globals, inputs, outputs,
  samplers and built-in variables (`gl_Position`, `gl_FragCoord`, ...) are members of the
  struct. Its functions are member functions, as written, and `out` and `inout`
  parameters are `thread T&`. Constants made of literals and constructors are `constant`
  at program scope; any other constant is a member.
- **Resources:**
  - A uniform block is a struct with std140's offsets: padding where std140 puts a member
    later, `packed_float3` for a vec3 followed by a scalar. Anything that cannot be made
    to agree is refused, never laid out wrong.
  - Members are read through `bulg_<Block>->`, and `bulg_Params`'s through
    `bulg_params->`: a struct with the same std140 offsets as GL's block, so one buffer
    of bytes serves both stages and both backends.
- **The entry point is `bulg_main`.**
  - Buffers: the blocks from 0 in the order of the text, then `bulg_Params`.
  - Textures and samplers: from 0 in the order of the text.
  - Vertex attributes: their location.
  - Varyings match by name (`[[user(name)]]`), and `flat` is kept.
  - Fragment outputs: `[[color(location)]]`.
- **Coordinates:** the vertex entry hands Metal `gl_Position` with y negated and depth
  moved from -1..1 to 0..1. Memory rows, texture coordinates, `gl_FragCoord` and the
  sign of `dFdy` then keep GL's numbers, and a texture drawn in one pass is sampled in
  the next as on GL. A target shown on screen is upside down relative to Metal's
  convention: the host flips it when it presents it.
- **Maths:** a host compiles the texts with fast math off (`MTLMathModeSafe`, or
  `-fno-fast-math`): fast math assumes finite values, which the rule on NaN forbids.
- Checked by Apple's compiler: CI compiles the golden texts for macOS and iOS
  (`tests/metal_compile.sh`). The script does the same for any directory of emitted texts.

## WGSL

Not yet. It comes after the interpreter.
