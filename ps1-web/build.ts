// Builds dist/: index.js, ps1.wasm beside it, and the .d.ts files.
import { $ } from 'bun';
import { copyFileSync, mkdirSync, rmSync } from 'node:fs';

const here = new URL('./', import.meta.url).pathname;
const wasm = new URL('../zig-out/bin/emulator.wasm', import.meta.url).pathname;

rmSync(here + 'dist', { recursive: true, force: true });
mkdirSync(here + 'dist');

const lib = await Bun.build({
  entrypoints: [here + 'src/index.ts'],
  outdir: here + 'dist',
  target: 'browser',
  format: 'esm',
});
if (!lib.success) {
  for (const log of lib.logs) console.error(log);
  process.exit(1);
}

copyFileSync(wasm, here + 'dist/ps1.wasm');
await $`bun x tsc -p ${here}tsconfig.build.json`;
