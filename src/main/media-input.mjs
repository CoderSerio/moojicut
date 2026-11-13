export const MAX_CHUNK_BYTES = 16 * 1024 * 1024;

export function number(value, name, min, max, integer = false) {
  if (!Number.isFinite(value) || value < min || value > max || (integer && !Number.isInteger(value))) {
    throw new Error(`Invalid ${name}.`);
  }
  return value;
}

export function validateBytes(value, limit = MAX_CHUNK_BYTES) {
  if (!(value instanceof Uint8Array) || value.byteLength === 0 || value.byteLength > limit) {
    throw new Error(`Expected between 1 and ${limit} bytes.`);
  }
  return Buffer.from(value);
}

export function validatePng(value) {
  const bytes = validateBytes(value, 64 * 1024 * 1024);
  if (bytes.length < 24 || !bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) {
    throw new Error('The image must be a PNG.');
  }
  number(bytes.readUInt32BE(16), 'image width', 1, 32768, true);
  number(bytes.readUInt32BE(20), 'image height', 1, 32768, true);
  return bytes;
}
