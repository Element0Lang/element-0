// Runs a wasm32-wasi binary under Node's built-in WASI implementation.
// Usage: node tools/run_wasi.mjs zig-out/bin/e1_ffi_pow.wasm [args...]
import { readFile } from 'node:fs/promises';
import { WASI } from 'node:wasi';

const [, , file, ...args] = process.argv;
if (!file) {
  console.error('usage: node tools/run_wasi.mjs <program.wasm> [args...]');
  process.exit(2);
}
const wasi = new WASI({
  version: 'preview1',
  args: [file, ...args],
  env: process.env,
  preopens: { '/': process.cwd() },
  returnOnExit: true,
});
const module = await WebAssembly.compile(await readFile(file));
const instance = await WebAssembly.instantiate(module, wasi.getImportObject());
process.exit(wasi.start(instance));
