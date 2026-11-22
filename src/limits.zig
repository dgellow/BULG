//! Bounds on what a session accepts, so that no input, however hostile, can exhaust the
//! stack or grow without end: past a bound the input is refused with a diagnostic.

pub const Limits = struct {
    /// bytes in one source
    source_bytes: u32 = 4 * 1024 * 1024,
    /// tokens in one source
    tokens: u32 = 1 << 20,
    /// nesting of expressions, statements and blocks (the parser and the checker recurse)
    nesting: u16 = 256,
    /// diagnostics kept; the rest are counted, not stored
    diagnostics: u16 = 64,
};
