import type { DiscInput } from './protocol';

const extension = (name: string) => name.slice(name.lastIndexOf('.') + 1).toLowerCase();
const stem = (name: string) => name.replace(/\.[^.]*$/, '').toLowerCase();
const baseName = (path: string) => path.split(/[\\/]/).pop() ?? path;

/**
 * Turns picked files (an `<input type=file multiple>` or a folder) into a
 * disc: a `.chd` wins; else the alphabetically first `.cue`, since a
 * multi-disc folder holds several and directory order differs between
 * browsers; else the largest `.bin`.
 */
export async function discFromFiles(files: Iterable<File>): Promise<DiscInput> {
  const all = [...files];
  const chd = all.find((f) => extension(f.name) === 'chd');
  if (chd) return { bin: chd, ...sidecars(chd.name, all), name: chd.name };

  const cues = all.filter((f) => extension(f.name) === 'cue').sort((a, b) => a.name.localeCompare(b.name));
  const cue = cues[0];
  if (cue) {
    const { text, bins } = layOut(await cue.text(), all);
    return { bin: new Blob(bins), cue: text, ...sidecars(cue.name, all), name: cue.name };
  }

  const bin = all.filter((f) => extension(f.name) === 'bin').sort((a, b) => b.size - a.size)[0];
  if (bin) return { bin, ...sidecars(bin.name, all), name: bin.name };

  throw new Error('No disc image among the files: expected a .chd, a .cue with its .bin files, or a .bin');
}

/**
 * The cue's FILEs in cue order, and the cue with a `REM FILESIZE` line
 * before each: that is how the core finds the seams once the images are
 * concatenated. The `Blob` built from `bins` is lazy, so nothing is copied here.
 */
export function layOut(cue: string, files: File[]): { text: string; bins: File[] } {
  const byName = new Map(files.map((f) => [f.name.toLowerCase(), f]));
  const bins: File[] = [];
  let text = '';
  for (const line of cue.split(/\r?\n/)) {
    const m = /^\s*FILE\s+(?:"([^"]+)"|(\S+))/i.exec(line);
    if (m) {
      const named = (m[1] ?? m[2])!;
      const bin = byName.get(baseName(named).toLowerCase());
      if (!bin) throw new Error(`The cue names "${named}", which is not among the files`);
      bins.push(bin);
      text += `REM FILESIZE ${bin.size}\n`;
    }
    text += line + '\n';
  }
  return { text, bins };
}

/** The LibCrypt sidecar and the PPF patch that belong to the disc, each only when present. */
function sidecars(discName: string, files: File[]): Pick<DiscInput, 'sbi' | 'ppf'> {
  const sbi = beside(discName, files, 'sbi');
  const ppf = beside(discName, files, 'ppf');
  return { ...(sbi && { sbi }), ...(ppf && { ppf }) };
}

/** The file named after the disc, or the only one of its kind present. Another disc's names sectors of a different image. */
function beside(discName: string, files: File[], ext: string): File | undefined {
  const candidates = files.filter((f) => extension(f.name) === ext);
  return candidates.find((f) => stem(f.name) === stem(discName)) ?? (candidates.length === 1 ? candidates[0] : undefined);
}
