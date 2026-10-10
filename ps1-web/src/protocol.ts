/** What the player accepts wherever bytes go in. A Blob is read lazily, in the worker. */
export type Binary = Blob | ArrayBuffer | Uint8Array;

/** A disc as the player takes it. `discFromFiles` builds one from picked files. */
export interface DiscInput {
  bin: Binary;
  /** The cue text. Omit for a CHD or a raw single-track `.bin`. */
  cue?: string;
  /** The LibCrypt sidecar some PAL discs need. */
  sbi?: Binary;
  /** A PPF patch (a translation or fix) to apply to the disc. */
  ppf?: Binary;
  /** The file the disc was picked as, for display. */
  name?: string;
}

export async function toBytes(b: Binary): Promise<Uint8Array> {
  if (b instanceof Uint8Array) return b;
  if (b instanceof ArrayBuffer) return new Uint8Array(b);
  return new Uint8Array(await b.arrayBuffer());
}
