// MediaRecorder timeslices can grow after sleep or a busy renderer. Keep every
// IPC payload within the host's limit without loading an entire blob into RAM.
export async function appendBlobInChunks(blob, append) {
  const chunkSize = 16 * 1024 * 1024;
  for (let offset = 0; offset < blob.size; offset += chunkSize) {
    await append(new Uint8Array(await blob.slice(offset, offset + chunkSize).arrayBuffer()));
  }
}
