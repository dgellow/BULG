// Compiles and links every GLSL ES 3.00 program under a directory (NAME.vert and NAME.frag,
// as `glint emit --dialect es300` writes them; files of other dialects are left alone) in
// Chromium's WebGL 2, which checks them through ANGLE. Prints each failure with the
// driver's log; exits 1 on any. Needs node and Playwright (with its Chromium).
//   node tests/webgl_es300.mjs DIR
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { createRequire } from 'node:module';

// require() so a globally installed Playwright is found as well as a local one
const { chromium } = createRequire(import.meta.url)('playwright');

const files = [];
const walk = (d) => {
  for (const f of readdirSync(d).sort()) {
    const p = join(d, f);
    if (statSync(p).isDirectory()) walk(p);
    else if (f.endsWith('.frag')) files.push(p.slice(0, -5));
  }
};
walk(process.argv[2]);
const programs = files
  .map((base) => ({ name: base, vert: readFileSync(base + '.vert', 'utf8'), frag: readFileSync(base + '.frag', 'utf8') }))
  .filter((p) => p.frag.startsWith('#version 300 es'));

const browser = await chromium.launch({ args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
const page = await browser.newPage();
await page.setContent('<canvas></canvas>');
const results = await page.evaluate((programs) => {
  const gl = document.querySelector('canvas').getContext('webgl2');
  if (!gl) return [{ name: '(webgl2)', log: 'no WebGL 2 context' }];
  const failed = [];
  for (const p of programs) {
    const shader = (type, text) => {
      const s = gl.createShader(type);
      gl.shaderSource(s, text);
      gl.compileShader(s);
      return s;
    };
    const v = shader(gl.VERTEX_SHADER, p.vert);
    const f = shader(gl.FRAGMENT_SHADER, p.frag);
    const prog = gl.createProgram();
    gl.attachShader(prog, v);
    gl.attachShader(prog, f);
    gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) {
      failed.push({ name: p.name, log: [gl.getShaderInfoLog(v), gl.getShaderInfoLog(f), gl.getProgramInfoLog(prog)].filter(Boolean).join('\n') });
    }
    gl.deleteProgram(prog);
    gl.deleteShader(v);
    gl.deleteShader(f);
  }
  return failed;
}, programs);
await browser.close();
for (const r of results) console.log(`${r.name}: ${r.log.trim()}`);
console.log(`glint es300: ${programs.length - results.length} of ${programs.length} programs compile and link in WebGL 2`);
process.exit(results.length ? 1 : 0);
