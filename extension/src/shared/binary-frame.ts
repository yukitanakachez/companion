import { MAX_CHUNK_BYTES, type BinaryFrameHeader } from "../../../contracts/ts/protocol";

export function encodeBinaryFrame(header: BinaryFrameHeader, payload: Uint8Array): Uint8Array {
  if (payload.length > MAX_CHUNK_BYTES) throw new RangeError(`payload of ${payload.length} bytes exceeds ${MAX_CHUNK_BYTES}`);
  const json = new TextEncoder().encode(JSON.stringify(header));
  const frame = new Uint8Array(4 + json.length + payload.length);
  new DataView(frame.buffer).setUint32(0, json.length);
  frame.set(json, 4);
  frame.set(payload, 4 + json.length);
  return frame;
}

export function decodeBinaryFrame(frame: Uint8Array): { header: BinaryFrameHeader; payload: Uint8Array } {
  if (frame.length < 4) throw new RangeError("truncated frame: no header length");
  const n = new DataView(frame.buffer, frame.byteOffset, frame.byteLength).getUint32(0);
  if (frame.length < 4 + n) throw new RangeError("truncated frame: incomplete header");
  const header = JSON.parse(new TextDecoder().decode(frame.subarray(4, 4 + n))) as BinaryFrameHeader;
  return { header, payload: frame.subarray(4 + n) };
}
