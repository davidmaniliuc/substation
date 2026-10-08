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

const SECTOR = 2352;

/**
 * The smallest disc `discid` reads: licence area at LBA 4, the primary
 * volume descriptor at 16, its root directory at 22 and SYSTEM.CNF at 30.
 * Mode 2 sectors, so user data starts 24 bytes in. Mirrors
 * `ps1-core/tests/discid_test.zig`'s builder.
 */
export function syntheticDisc(serialLine = 'BOOT = cdrom:\\SLUS_005.30;1\r\nTCB = 4\r\n', volumeId = 'CROC'): Uint8Array {
  const image = new Uint8Array(SECTOR * 40);
  const ascii = (s: string) => new TextEncoder().encode(s);
  const writeSector = (lba: number, payload: Uint8Array) => {
    image[lba * SECTOR + 15] = 2;
    image.set(payload, lba * SECTOR + 24);
  };
  const dirRecord = (out: Uint8Array, at: number, extent: number, length: number, name: Uint8Array) => {
    const size = 33 + name.length + ((name.length + 1) % 2);
    const view = new DataView(out.buffer, out.byteOffset + at);
    out[at] = size;
    view.setUint32(2, extent, true);
    view.setUint32(10, length, true);
    out[at + 32] = name.length;
    out.set(name, at + 33);
    return size;
  };

  writeSector(4, ascii('          Licensed  by          Sony Computer Entertainment Amer  ica '));

  const pvd = new Uint8Array(2048);
  pvd[0] = 1;
  pvd.set(ascii('CD001'), 1);
  pvd[6] = 1;
  pvd.fill(0x20, 40, 72);
  pvd.set(ascii(volumeId), 40);
  dirRecord(pvd, 156, 22, 2048, new Uint8Array([0]));
  writeSector(16, pvd);

  const cnf = ascii(serialLine);
  const rootDir = new Uint8Array(2048);
  let at = 0;
  at += dirRecord(rootDir, at, 22, 2048, new Uint8Array([0]));
  at += dirRecord(rootDir, at, 22, 2048, new Uint8Array([1]));
  dirRecord(rootDir, at, 30, cnf.length, ascii('SYSTEM.CNF;1'));
  writeSector(22, rootDir);
  writeSector(30, cnf);
  return image;
}
