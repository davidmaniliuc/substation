import { describe, expect, test } from 'bun:test';
import { discFromFiles } from '../src/disc-files';

const file = (name: string, size = 16) => new File([new Uint8Array(size)], name);

describe('discFromFiles', () => {
  test('a .chd wins over everything else, and takes its matching .sbi', async () => {
    const disc = await discFromFiles([file('Game.cue'), file('Game.chd', 100), file('game.sbi'), file('other.sbi')]);
    expect(disc.name).toBe('Game.chd');
    expect(disc.cue).toBeUndefined();
    expect((disc.sbi as File).name).toBe('game.sbi');
  });

  test('a cue concatenates its FILEs in cue order with REM FILESIZE seams', async () => {
    const cue = new File(
      ['FILE "Track 2.bin" BINARY\n  TRACK 01 MODE2/2352\nFILE track1.BIN BINARY\n  TRACK 02 AUDIO\n'],
      'Game.cue',
    );
    const disc = await discFromFiles([file('track1.bin', 10), cue, file('Track 2.bin', 20)]);
    expect(disc.cue).toBe(
      'REM FILESIZE 20\nFILE "Track 2.bin" BINARY\n  TRACK 01 MODE2/2352\nREM FILESIZE 10\nFILE track1.BIN BINARY\n  TRACK 02 AUDIO\n\n',
    );
    expect((disc.bin as Blob).size).toBe(30);
  });

  test('a FILE carrying a directory path is found by its base name', async () => {
    const cue = new File(['FILE "Disc\\Track 01.bin" BINARY\n  TRACK 01 MODE2/2352\n'], 'g.cue');
    const disc = await discFromFiles([cue, file('Track 01.bin', 7)]);
    expect((disc.bin as Blob).size).toBe(7);
  });

  test('a folder of several discs boots the alphabetically first cue', async () => {
    const one = new File(['FILE "d1.bin" BINARY\n TRACK 01 MODE2/2352\n'], 'Game (Disc 1).cue');
    const two = new File(['FILE "d2.bin" BINARY\n TRACK 01 MODE2/2352\n'], 'Game (Disc 2).cue');
    const disc = await discFromFiles([two, file('d2.bin'), one, file('d1.bin')]);
    expect(disc.name).toBe('Game (Disc 1).cue');
  });

  test('a cue naming a missing file says which', async () => {
    const cue = new File(['FILE "gone.bin" BINARY\n'], 'g.cue');
    await expect(discFromFiles([cue])).rejects.toThrow('gone.bin');
  });

  test('without a cue or chd, the largest .bin is the disc', async () => {
    const disc = await discFromFiles([file('small.bin', 5), file('big.bin', 50)]);
    expect(disc.name).toBe('big.bin');
  });

  test('a lone .sbi is used even when its name does not match', async () => {
    const disc = await discFromFiles([file('game.bin'), file('SLES_012.34.sbi')]);
    expect((disc.sbi as File).name).toBe('SLES_012.34.sbi');
  });

  test('no disc image at all is an error', async () => {
    await expect(discFromFiles([file('readme.txt')])).rejects.toThrow('No disc image');
  });
});
