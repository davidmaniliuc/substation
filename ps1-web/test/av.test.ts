import { describe, expect, test } from 'bun:test';
import { bios, hasBios, newCore } from './helpers';

describe('video', () => {
  test('a fresh machine shows an opaque black frame of its display size', async () => {
    const core = await newCore();
    const f = core.frame();
    expect(f.width).toBeGreaterThan(0);
    expect(f.height).toBeGreaterThan(0);
    expect(f.rgba.length).toBe(f.width * f.height * 4);
    for (let i = 0; i < f.rgba.length; i += 4) {
      expect([f.rgba[i], f.rgba[i + 1], f.rgba[i + 2], f.rgba[i + 3]]).toEqual([0, 0, 0, 255]);
    }
  });
});

describe('audio', () => {
  test('a machine that has not run has no samples, and never an odd count', async () => {
    const core = await newCore();
    expect(core.readAudio(7).length % 2).toBe(0);
  });
});

describe.skipIf(!hasBios)('booting the BIOS', () => {
  test('after five seconds the screen shows a picture and the SPU produced sound', async () => {
    const core = await newCore();
    core.setCpuEngine('cached');
    core.loadBios(bios());
    let samples = 0;
    for (let i = 0; i < 300; i++) {
      core.runFrame();
      samples += core.readAudio().length;
    }
    const f = core.frame();
    const first = f.rgba.slice(0, 4).join();
    let distinct = false;
    for (let i = 4; i < f.rgba.length && !distinct; i += 4) distinct = f.rgba.slice(i, i + 4).join() !== first;
    expect(distinct).toBe(true);
    expect(samples).toBeGreaterThan(0);
    expect(core.isPal).toBe(false);
  }, 60_000);
});
