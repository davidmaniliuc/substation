import { readFileSync } from 'node:fs';
import { describe, expect, test } from 'bun:test';
import { bios, codeOf, root, hasBios, newCore } from './helpers';

describe('BIOS', () => {
  test('an image that is not 512 KB is refused', async () => {
    const core = await newCore();
    expect(codeOf(() => core.loadBios(new Uint8Array(1000)))).toBe('BAD_BIOS_SIZE');
  });

  test('an image missing from the table loads, unidentified', async () => {
    const core = await newCore();
    expect(core.loadBios(new Uint8Array(512 * 1024))).toEqual({
      known: false,
      region: null,
      version: null,
      description: null,
    });
  });

  test.skipIf(!hasBios)('SCPH-1001 is identified as an American BIOS', async () => {
    const core = await newCore();
    const info = core.loadBios(bios());
    expect(info.known).toBe(true);
    expect(info.region).toBe('america');
  });
});

describe('machine', () => {
  test('running a frame with no BIOS does nothing', async () => {
    const core = await newCore();
    expect(() => core.runFrame()).not.toThrow();
  });

  test('the cached engine is available and the JIT is not', async () => {
    const core = await newCore();
    expect(() => core.setCpuEngine('cached')).not.toThrow();
    expect(codeOf(() => core.setCpuEngine('jit' as never))).toBe('ENGINE_UNAVAILABLE');
  });

  test('reset rebuilds the machine', async () => {
    const core = await newCore();
    expect(() => core.reset()).not.toThrow();
  });
});

describe('eboot', () => {
  test("identifyDisc reports an eboot's disc count and title", async () => {
    const core = await newCore(false);
    const pbp = new Uint8Array(readFileSync(root + 'ps1-core/tests/fixtures/two-disc.pbp'));
    const info = core.identifyDisc(pbp);
    expect(info.discs).toBe(2);
    expect(info.imageTitle).toBe('Fixture');
    expect(codeOf(() => core.identifyDisc(pbp, { disc: 2 }))).toBe('BAD_PBP');
  });
});
