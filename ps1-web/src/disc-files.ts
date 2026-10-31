import type { DiscInput } from './protocol';

const extension = (name: string) => name.slice(name.lastIndexOf('.') + 1).toLowerCase();
const stem = (name: string) => name.replace(/\.[^.]*$/, '').toLowerCase();
const baseName = (path: string) => path.split(/[\\/]/).pop() ?? path;

/**
 * Turns picked files (an `<input type=file multiple>` or a folder) into a
 * disc: a `.chd` wins; else the alphabetically first `.cue`, since a
 * multi-disc folder holds several and directory order differs between
 * browsers; else the first `.ccd` (its `.img` and `.sub`); else the first
 * `.mds` (its `.mdf`); else the largest `.pbp`, `.ecm`, `.iso`/`.img`, then
 * `.bin`. `disc` picks a disc of a `.pbp` eboot; a `.ppf` patches disc 0 only.
 */
export async function discFromFiles(files: Iterable<File>, options: { disc?: number } = {}): Promise<DiscInput> {
  const all = [...files];
  const chd = all.find((f) => extension(f.name) === 'chd');
  if (chd) return { bin: chd, ...sidecars(chd.name, all), name: chd.name };

  const cues = all.filter((f) => extension(f.name) === 'cue').sort((a, b) => a.name.localeCompare(b.name));
  const cue = cues[0];
  if (cue) {
    const { text, bins } = layOut(await cue.text(), all);
    return { bin: new Blob(bins), cue: text, ...sidecars(cue.name, all), name: cue.name };
  }

  const ccd = all.filter((f) => extension(f.name) === 'ccd').sort((a, b) => a.name.localeCompare(b.name))[0];
  if (ccd) {
    const img = all.find((f) => extension(f.name) === 'img' && stem(f.name) === stem(ccd.name));
    if (!img) throw new Error(`The CloneCD sheet "${ccd.name}" has no ${stem(ccd.name)}.img beside it`);
    const sub = all.find((f) => extension(f.name) === 'sub' && stem(f.name) === stem(ccd.name));
    const { sbi, ppf } = sidecars(ccd.name, all);
    return { bin: img, cue: await ccd.text(), ...((sub ?? sbi) && { sbi: sub ?? sbi }), ...(ppf && { ppf }), name: ccd.name };
  }

  const mds = all.filter((f) => extension(f.name) === 'mds').sort((a, b) => a.name.localeCompare(b.name))[0];
  if (mds) {
    const mdf = all.find((f) => extension(f.name) === 'mdf' && stem(f.name) === stem(mds.name));
    if (!mdf) throw new Error(`The Alcohol sheet "${mds.name}" has no ${stem(mds.name)}.mdf beside it`);
    return { bin: mdf, cue: new Uint8Array(await mds.arrayBuffer()), // binary: text() would corrupt it
       ...sidecars(mds.name, all), name: mds.name };
  }

  for (const ext of ['pbp', 'ecm', 'iso/img', 'bin']) {
    const exts = ext.split('/');
    const bin = all.filter((f) => exts.includes(extension(f.name))).sort((a, b) => b.size - a.size)[0];
    if (!bin) continue;
    const { sbi, ppf } = sidecars(bin.name, all);
    const disc = options.disc ?? 0;
    // A patch is made against one disc's sectors: an eboot's other discs get none.
    const patch = ext === 'pbp' && disc !== 0 ? undefined : ppf;
    return {
      bin,
      ...(sbi && { sbi }),
      ...(patch && { ppf: patch }),
      ...(options.disc !== undefined && ext === 'pbp' && { disc }),
      name: bin.name,
    };
  }

  throw new Error(
    'No disc image among the files: expected a .chd, a .cue with its .bin files, a .ccd with its .img, an .mds with its .mdf, a .pbp, an .ecm, an .iso or a .bin',
  );
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
