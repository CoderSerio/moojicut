import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';
import { Readable } from 'node:stream';

export function createMediaHandler(store) {
  return async (request) => {
    try {
      const url = new URL(request.url);
      if (url.hostname !== 'recording' || !['GET', 'HEAD'].includes(request.method)) return new Response(null, { status: 404 });
      const record = store.get(url.pathname.slice(1));
      if (record.state !== 'complete') return new Response(null, { status: 404 });
      const { size } = await stat(record.filename);
      const headers = { 'Content-Type': record.mimeType || 'video/webm', 'Accept-Ranges': 'bytes', 'Cache-Control': 'no-store' };
      const range = request.headers.get('range');
      let start = 0;
      let end = size - 1;
      let status = 200;
      if (range) {
        const match = /^bytes=(\d*)-(\d*)$/.exec(range);
        if (!match || (!match[1] && !match[2])) return new Response(null, { status: 416, headers: { 'Content-Range': `bytes */${size}` } });
        if (!match[1]) start = Math.max(0, size - Number(match[2]));
        else { start = Number(match[1]); if (match[2]) end = Math.min(Number(match[2]), end); }
        if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start > end || start >= size) return new Response(null, { status: 416, headers: { 'Content-Range': `bytes */${size}` } });
        headers['Content-Range'] = `bytes ${start}-${end}/${size}`;
        status = 206;
      }
      headers['Content-Length'] = String(end - start + 1);
      return new Response(request.method === 'HEAD' ? null : Readable.toWeb(createReadStream(record.filename, { start, end })), { status, headers });
    } catch { return new Response(null, { status: 404 }); }
  };
}
