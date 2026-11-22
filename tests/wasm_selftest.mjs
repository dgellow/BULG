// Runs the freestanding self-test (src/selftest.zig) under node: the library must work
// without libc, files or threads. Usage: node tests/wasm_selftest.mjs <glint_selftest.wasm>
import { readFileSync } from 'node:fs';

const bytes = readFileSync(process.argv[2]);
const { instance } = await WebAssembly.instantiate(bytes, {});
const n = instance.exports.glint_selftest();
if (n <= 0) {
  console.error(`glint: wasm self-test failed (${n})`);
  process.exit(1);
}
console.log(`glint: wasm self-test parsed and printed ${n} nodes, and checked a program`);
