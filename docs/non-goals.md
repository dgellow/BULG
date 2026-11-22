# What Glint is not

Each line below is a decision. A change to one needs a program that cannot be written
without it, or a second target that requires it.

- **No GPU API calls.** Glint never touches GL, Metal or WebGPU. It emits shader text and
  describes it (reflection); the host compiles, binds and draws.
- **No render or pass API.** How passes, targets and readbacks are scheduled belongs to the
  host. Pass declarations, when they come, are descriptions in the reflection.
- **No SPIR-V or binary output.** Every target is text; the driver compilers optimise.
- **No optimiser** beyond constant folding, dead-code removal and specialisation.
- **No preprocessor**, no pointers, no recursion, no bindless resources, no compute stage.
  Generics and interfaces come only once the language is settled in use.
- **No knowledge of a host.** Names that mean something to one program (what drives a
  parameter, which effects exist) reach Glint only as opaque metadata.
- **No C API yet.** It comes when a host that is not written in Zig needs the compiler;
  the Zig API is kept plain enough (handles, plain data) for it to be a thin wrapper.
