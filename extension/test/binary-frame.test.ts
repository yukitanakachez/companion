import { describe, expect, it } from "vitest";
import { MAX_CHUNK_BYTES } from "../../contracts/ts/protocol";
import { decodeBinaryFrame, encodeBinaryFrame } from "../src/shared/binary-frame";

const header = { id: "r-2", seq: 0, last: true };

describe("binary frames", () => {
  it("round-trips with a 4-byte big-endian header length", () => {
    const payload = new TextEncoder().encode("%PDF");
    const frame = encodeBinaryFrame(header, payload);
    expect(new DataView(frame.buffer, frame.byteOffset).getUint32(0)).toBe(frame.length - 4 - 4);
    const out = decodeBinaryFrame(frame);
    expect(out.header).toEqual(header);
    expect(new TextDecoder().decode(out.payload)).toBe("%PDF");
  });
  it("accepts exactly MAX_CHUNK_BYTES and rejects one byte more", () => {
    expect(decodeBinaryFrame(encodeBinaryFrame(header, new Uint8Array(MAX_CHUNK_BYTES))).payload.length).toBe(MAX_CHUNK_BYTES);
    expect(() => encodeBinaryFrame(header, new Uint8Array(MAX_CHUNK_BYTES + 1))).toThrow(RangeError);
  });
  it("decode rejects a truncated frame", () => {
    const frame = encodeBinaryFrame(header, new Uint8Array(4));
    expect(() => decodeBinaryFrame(frame.subarray(0, 2))).toThrow();
    expect(() => decodeBinaryFrame(frame.subarray(0, 8))).toThrow();
  });
});
