import { existsSync, readFileSync } from 'node:fs';
import { Ps1Core } from '../src/core';
import { Ps1Error, type Ps1ErrorCode } from '../src/errors';

/** The repo root: the wasm, the BIOS and `games/` are found relative to it. */
export const root = new URL('../../', import.meta.url).pathname;

const wasm = readFileSync(root + 'zig-out/bin/emulator.wasm');
export const biosPath = root + 'SCPH-1001_BIOS_1995_US.bin';
export const hasBios = existsSync(biosPath);
export const bios = () => new Uint8Array(readFileSync(biosPath));

export const newCore = (machine = true) => Ps1Core.create(wasm, { machine, onLog: () => {} });

/** The `Ps1Error` code `fn` throws, or undefined when it returns. */
export function codeOf(fn: () => unknown): Ps1ErrorCode | undefined {
  try {
    fn();
  } catch (e) {
    if (e instanceof Ps1Error) return e.code;
    throw e;
  }
  return undefined;
}
