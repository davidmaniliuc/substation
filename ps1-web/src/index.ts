import { compile, Ps1Core, type DiscInfo } from './core';
import { toBytes, type Binary } from './protocol';

export { Ps1Core, compile, BIOS_BYTES, MEMCARD_BYTES, AUDIO_SAMPLE_RATE } from './core';
export type { BiosInfo, CpuEngine, DiscBytes, DiscInfo, Frame, Region, WasmSource } from './core';
export { Ps1Error, type Ps1ErrorCode } from './errors';
export { discFromFiles, layOut } from './disc-files';
export { toBytes, type Binary, type DiscInput } from './protocol';

const modules = new Map<string, Promise<WebAssembly.Module>>();

/**
 * Identifies a disc with no BIOS and no machine: for a catalogue's upload
 * form. Each call gets its own short-lived instance, so the image's copy
 * in wasm memory is released with it. Pass the WHOLE image.
 */
export async function identifyDisc(bin: Binary, options: { wasmUrl?: string | URL } = {}): Promise<DiscInfo> {
  const url = String(options.wasmUrl ?? new URL('./ps1.wasm', import.meta.url));
  let module = modules.get(url);
  if (!module) modules.set(url, (module = compile(url)));
  const core = await Ps1Core.create(await module, { machine: false });
  return core.identifyDisc(await toBytes(bin));
}
