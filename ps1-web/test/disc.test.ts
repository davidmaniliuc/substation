import { describe, expect, test } from 'bun:test';
import { codeOf, newCore, syntheticDisc } from './helpers';

describe('identifyDisc', () => {
  test('reads region, serial, volume id and the catalogued title', async () => {
    const core = await newCore(false);
    expect(core.identifyDisc(syntheticDisc())).toEqual({
      region: 'america',
      serial: 'SLUS-00530',
      volumeId: 'CROC',
      title: 'Croc - Legend of the Gobbos',
      set: null,
    });
  });

  test('a disc with no SYSTEM.CNF still reports its licence region', async () => {
    const core = await newCore(false);
    const info = core.identifyDisc(syntheticDisc('nothing here'));
    expect(info.region).toBe('america');
    expect(info.serial).toBe('');
    expect(info.title).toBeNull();
  });

  test('fewer bytes than one sector is refused', async () => {
    const core = await newCore(false);
    expect(codeOf(() => core.identifyDisc(new Uint8Array(100)))).toBe('BAD_CUE');
  });
});

describe('loadDisc', () => {
  const cue = 'FILE "game.bin" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n';

  test('a raw image, an image with a cue, and a replacement disc all load', async () => {
    const core = await newCore();
    core.loadDisc({ bin: syntheticDisc() });
    core.loadDisc({ bin: syntheticDisc(), cue });
    expect(() => core.loadDisc({ bin: syntheticDisc() })).not.toThrow();
  });

  test('every malformed input is refused with its own code', async () => {
    const core = await newCore();
    expect(codeOf(() => core.loadDisc({ bin: new Uint8Array(100) }))).toBe('BAD_CUE');
    expect(codeOf(() => core.loadDisc({ bin: syntheticDisc(), cue: 'REM nothing\n' }))).toBe('BAD_CUE');
    expect(codeOf(() => core.loadDisc({ bin: syntheticDisc(), cue: 'FILE "a.bin" BINARY\nREM no track\n' }))).toBe('BAD_CUE');
    const twoFiles = 'FILE "a.bin" BINARY\n TRACK 01 MODE2/2352\n INDEX 01 00:00:00\nFILE "b.bin" BINARY\n TRACK 02 AUDIO\n INDEX 01 00:00:00\n';
    expect(codeOf(() => core.loadDisc({ bin: syntheticDisc(), cue: twoFiles }))).toBe('MULTI_FILE_CUE');
    expect(codeOf(() => core.loadDisc({ bin: syntheticDisc(), sbi: new Uint8Array([1, 2, 3, 4]) }))).toBe('BAD_SBI');
    const fakeChd = new Uint8Array(4096);
    fakeChd.set(new TextEncoder().encode('MComprHD'));
    expect(codeOf(() => core.loadDisc({ bin: fakeChd }))).toBe('BAD_CHD');
    expect(codeOf(() => core.loadDisc({ bin: fakeChd, cue }))).toBe('BAD_CHD');
  });

  test('a refused disc leaves the core able to load the next one', async () => {
    const core = await newCore();
    codeOf(() => core.loadDisc({ bin: new Uint8Array(100) }));
    expect(() => core.loadDisc({ bin: syntheticDisc() })).not.toThrow();
  });

  test('a disc large enough to grow memory still loads and identifies', async () => {
    const core = await newCore();
    const big = new Uint8Array(64 * 1024 * 1024);
    big.set(syntheticDisc());
    core.loadDisc({ bin: big });
    expect(core.identifyDisc(syntheticDisc()).serial).toBe('SLUS-00530');
  });
});
