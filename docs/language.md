# The BULG language, v0

BULG is GLSL ES 3.00 in shape and strict in its rules. The preprocessor is replaced by
declarations (modules, aliases, spec constants, programs). This page is the
specification. Each rule names the test that holds it: `parser:` tests are in
`src/syntax/Parser.zig`, `sema:` tests in `src/sema/tests.zig`.

## Files, modules and names

- A source is a module. Its name is its path, without a final `.bulg`:
  `art/art_core.bulg` is `art/art_core`. Paths are relative to the root of the shader
  tree, never to the importing file.
- The order of declarations in a module is free: a function may call one declared after
  it, and a constant may be used before it (sema: names, scopes and declarations).
- `import "m";` makes the module-level names of `m` visible. `import "m" : a, b;` makes
  only `a` and `b` visible. An import is not transitive: `m`'s own imports are not
  visible. A name that two imported modules declare is an error where it is used, not
  where it is imported (sema: aliases, imports, uniform blocks).
- A module's own declarations come before its imports' when a name is looked up. Inside a
  function the order is locals (innermost first), then parameters, then module-level
  names, then the built-in variables.
- Reserved: names starting with `gl_` or containing `__`, the built-in type names, and the
  built-in function names. A module cannot define or overload a built-in function.
- BULG's own words (`import alias block param spec extern program template link`) are
  keywords. Using one as a name says so (parser: a keyword used as a name says so).

## Types

- `bool int uint float`, and `half`, a 16-bit float where the target has one (`float`
  on GL in v0).
- Vectors `bvecN ivecN uvecN vecN hvecN` and square matrices `matN hmatN`, with N from 2
  to 4.
- `sampler2D`, only as a `uniform` or as an `in` parameter.
- Structs, which cannot contain themselves or a sampler.
- Fixed arrays of one dimension, `T[N]` or `T name[N]`. `N` is a positive constant
  integer (sema: constants and array sizes).
- `void`, only as a return type.
- BULG converts nothing implicitly: `float x = 1;` is an error, and so are `1. + 1` and
  `sin(1)` (sema: no implicit conversions). Constructors convert: `float(i)`,
  `ivec2(v.xy)`.

## Declarations at module level

| Form | Is |
| -- | -- |
| `uniform T name;` | a value the host sets; no initialiser |
| `uniform block Name { T a; T b = default; };` | a std140 block; its members are module-level names |
| `in T name;`, `out T name;`, `flat`, `layout(location = n)` | stage inputs and outputs |
| `const T name = constant;` | a constant |
| `param T name = constant { meta };` | a value the host may tweak: a uniform with a default and metadata |
| `spec T name = constant { meta };` | a value fixed per variant (`bool`, `int`, `uint`, `float`) |
| `T name [= constant];` | a mutable global, private to each invocation |
| `alias name = expression;` | a name for an expression, replaced where it is used |
| `struct Name { T a; T b; };` | a struct type |
| `T f(params) { ... }` | a function |
| `T f(params);` | a prototype; its definition must be in the same module |
| `extern T f(params);` | a hole, filled by another module of the program |
| `program ...` | a program (below) |

- A declaration takes one storage kind. `flat` and `layout(location)` are only for `in`
  and `out`.
- Module-level initialisers are constant expressions (sema: constants and array sizes).
- Metadata `{ key, key(args) }` is for `param`, `spec` and `uniform`. Its arguments are
  constants, strings, or bare words that nothing declares (`curve(exp)`). BULG keeps the
  keys and passes them to the host (sema: metadata; below).
- A uniform block's members are laid out by std140; reflection gives each member's
  offset (sema: aliases, imports, uniform blocks).

## Metadata

```glsl
param float zoom = 1.6 { range(.5, 4.), step(.05), label("Zoom"), group("Camera"), unit("x") };
param vec3 tint = vec3(.2, .4, .9) { color, range(0., 1.) };
spec int STEPS = 96 { range(16, 128), tiers(48, 72, 96) };
param float drift = .3 { range(0., 1.), mod("music.bass", .5), curve(exp) };
```

BULG knows the core keys and checks them (sema: metadata):

| Key | Arguments | Is for | Means |
| -- | -- | -- | -- |
| `range(lo, hi)` | two numbers, `lo < hi` | numbers and their vectors | the values a tool offers; the default (each component) and the tiers lie in it |
| `step(s)` | a number above 0 | numbers and their vectors | the smallest change a tool makes |
| `label("…")` | a string | any | the name a tool shows |
| `group("…")` | a string | any | the heading a tool shows it under |
| `unit("…")` | a string | any | written after the value |
| `color` | none | `vec3`, `vec4` | a colour: a tool shows a swatch |
| `tiers(a, b, …)` | numbers, rising | `spec` constants | the values a host picks between by quality, lowest first |

- A key is given once on a declaration, unless a schema lets it repeat.
- Every other key is the host's. Without a schema BULG passes it on unchecked.
- A host may give a schema of its own keys (`Session.Options.meta_schema`, `bulg
  --meta-schema FILE`, `addShaderTree(.{ .meta_schema })`). With one, a key that neither
  BULG nor the schema has is an error, E0231, with the nearest known key as a hint; and
  the schema's keys have their arguments checked like the core's (E0230). A schema names
  each key, its arguments (`number`, `string` or `word`; for the last two, optionally the values allowed),
  which may be left out (`optional`) or repeated (`rest`, the last), and the
  declarations it may be on. It cannot redefine a core key. The format is ZON:

```zig
.{ .keys = .{
    .{ .name = "mod", .on = .{.param}, .doc = "follows a signal of the host",
       .args = .{ .{ .kind = .string }, .{ .kind = .number, .optional = true } } },
    .{ .name = "curve", .args = .{ .{ .kind = .word, .words = .{ "lin", "exp" } } } },
} }
```

## Functions

- Parameters are `in` (the default), `out` or `inout`, and may be `const` when `in`.
- An `out` or `inout` argument must be something that can be written.
- Overloads are told apart by parameter types. A call picks the overload whose parameter
  types are exactly the arguments' types.
- No function may call itself, directly or through others. In a program, that includes
  cycles through `extern`s (sema: cycles).
- `void main()` is a stage's entry point.

## Statements

- Blocks, declarations, expressions, `if`/`else`, `for`, `return`, `break`, `continue`,
  `discard`.
- `while`, `do`, `switch` and `precision` are named and refused (parser: GLSL forms BULG
  leaves out are named).
- A function's parameters and the top level of its body are one scope. Each block, each
  `for` and the body of each `if` and `for` opens a scope. A name declared twice in one
  scope is an error. An inner scope may hide an outer name (sema: names, scopes and
  declarations).
- A local's name is in scope after its initialiser.
- Locals take no qualifier but `const`. A `const` local is initialised with a constant
  expression.
- Conditions are `bool`.
- `break` and `continue` are only inside a loop (sema: statements).

## Expressions

- Operators have GLSL's precedence (parser: precedence). Arithmetic takes operands of one
  scalar kind. A scalar operand applies to every component of a vector or matrix operand.
  `*` of a matrix and a vector, a vector and a matrix, or two matrices is the linear
  algebra product. Other operators on vectors and matrices work per component.
- `%`, `&`, `|`, `^`, `~` take integers. A shift's operands may differ in signedness.
- `<`, `>`, `<=` and `>=` take scalars. `==` and `!=` take any two values of one type
  (not samplers).
- `&&`, `||`, `^^` and `!` take `bool`.
- `?:` takes a `bool` and two values of one type.
- No comma operator.
- Swizzles use one of `xyzw`, `rgba` or `stpq`, at most four letters, within the vector's
  size. A swizzle with a repeated letter cannot be written to (sema: what can be written).
- Indices are `int` or `uint`. A constant index past the end is an error (sema: swizzles,
  indices, fields).
- `a.length()` of an array is a constant `int`.
- Constructors (sema: constructors):
  - `T(x)` for a scalar `T` takes one argument and its first component.
  - `vecN(s)` fills the vector. `matN(s)` makes a diagonal matrix. `matN(m)` resizes a
    matrix.
  - Otherwise the arguments' components fill the result in order. Every argument must be
    used, and the components must be enough.
  - `S(a, b)` takes a struct's fields in order. `T[N](...)` takes exactly N elements.
- Integer literals are decimal, hex (`0x`) or octal (a leading `0`), with `u` for
  `uint`; a literal's bit pattern fits 32 bits. Float literals take an optional `f`.
  Literals keep their spelling to the emitters.
- Integer arithmetic wraps. NaN compares false, and no emitter may assume finite maths.

## Constant expressions

Literals, `const` and `spec` names, aliases of constant expressions, and constructors,
operators (not assignments, `++` or `--`), built-in functions without `out` parameters,
indices, swizzles and fields of constant expressions. BULG computes the value of
constant scalar integer, float and bool expressions where it needs one: array sizes,
locations and spec values. `spec` values are not known before the variant, so they cannot
size an array.

## Built-ins

- The functions of GLSL ES 3.00 chapter 8, less non-square matrices, samplers other than
  `sampler2D`, `textureGrad`, `textureOffset` and `textureProj`. `src/sema/builtins.zig`
  lists them.
- `dFdx`, `dFdy` and `fwidth` are for fragment stages.
- The variables keep their GL spellings:
  - fragment stages read `gl_FragCoord`, `gl_FrontFacing` and `gl_PointCoord`;
  - vertex stages write `gl_Position` and `gl_PointSize`, and read `gl_VertexID` and
    `gl_InstanceID`.

## Programs

```glsl
program template world { vertex "fullscreen"; fragment "world_main"; }
program reef : world { spec FADE = true; }
program cover_star_lattice : cover { link "worlds/star_lattice"; spec ART_COVER = true; }
```

- A program has a vertex and a fragment stage. A `template` is not built itself: it gives
  its items to the programs that name it as their parent.
- A child takes its parent's items, then its own. A later `vertex`, `fragment` or `spec`
  of the same name replaces an earlier one.
- Each stage links:
  - its entry module (with `void main()`);
  - every `link`ed module;
  - the module that declares the program;
  - and everything those modules import.
- Every `extern` reachable from `main` must be defined, with the same signature, by
  exactly one module of the stage.
- A stage may use only what it has. `discard`, derivatives and the fragment variables
  belong to the fragment stage; the vertex variables belong to the vertex stage.
- `spec NAME = value;` sets a spec constant of the stage's modules, with a constant of
  its type (sema: programs: stages, externs and spec values).

## Left out of v0

Using any of these gives a diagnostic:

- the preprocessor, `while`, `do`, `switch`, the comma operator;
- non-square matrices, arrays of arrays;
- samplers other than `sampler2D`;
- multiple render targets, `gl_FragDepth`, interface blocks other than `uniform block`;
- precision statements, `textureGrad`, `textureOffset`, `textureProj`;
- qualified names, generics.
