#!/usr/bin/env node
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';
import { rpc } from './client.mjs';
import { captureId, revision, annotationSchema, patchSchema, regionSchema } from './schemas.mjs';

const server = new McpServer({ name: 'mooncap', version: '0.2.0' }, {
  instructions: 'Mooncap is a local screenshot tool shared by people and agents. Call list_windows before capture; IDs may expire. Capture, annotate, crop and export are silent; only present and pin show UI. Call status to find the human activeCaptureId. All coordinates are original-image physical pixels, not screen logical points; preview origin equals document.viewport.x/y. Carry captureId and expectedRevision to avoid overwriting human edits. Read/preview again after revision_conflict. Confirming a screenshot rebases its coordinates to the saved region, so read its new revision before continuing. Exported PNG contains final flattened pixels. copy changes the clipboard but does not close the human editor. Screen permission must be granted in system settings.',
});
const readOnly = { readOnlyHint: true, openWorldHint: false };
const edit = { readOnlyHint: false, destructiveHint: false, openWorldHint: false };
const imageContent = (value) => {
  const dataUrl = value.image ?? value.preview ?? value.imageUrl;
  if (typeof dataUrl === 'string' && dataUrl.startsWith('data:image/png;base64,')) return { type: 'image', data: dataUrl.slice('data:image/png;base64,'.length), mimeType: 'image/png' };
  if (typeof value.pngBase64 === 'string') return { type: 'image', data: value.pngBase64, mimeType: 'image/png' };
  return null;
};
async function result(method, params, includePreview = false) {
  try {
    const value = await rpc(method, params);
    const metadata = structuredClone(value);
    if (metadata && typeof metadata === 'object') {
      delete metadata.image; delete metadata.imageUrl; delete metadata.pngBase64; delete metadata.preview;
    }
    const content = [{ type: 'text', text: JSON.stringify(metadata) }];
    if (includePreview) {
      const preview = method === 'preview' ? value : await rpc('preview', { captureId: value?.id || params.captureId });
      const image = imageContent(preview);
      if (image) content.push(image);
    }
    return { content };
  } catch (failure) {
    return { isError: true, content: [{ type: 'text', text: JSON.stringify({ error: failure.message, code: failure.code, details: failure.details }) }] };
  }
}
function tool(name, description, inputSchema, callback, annotations = edit) {
  server.registerTool(name, { description, inputSchema, annotations }, callback);
}
tool('status', 'Read app, permission and active screenshot status. Starts the tray app if necessary.', {}, () => result('status', {}), readOnly);
tool('list_windows', 'List current screen/window sources without saving screenshots. Use returned source IDs, never guess.', { types: z.array(z.enum(['window', 'screen'])).optional() }, (p) => result('list_windows', p), readOnly);
tool('capture', 'Capture a source silently. Optional region is in source physical pixels. Returns editable document and preview.', { sourceId: z.string().min(1).max(200), region: regionSchema.optional(), name: z.string().max(200).optional() }, (p) => result('capture', p, true));
tool('import_image', 'Import a local PNG, JPEG or WebP by absolute path. No dialog is shown.', { path: z.string().min(1), name: z.string().max(200).optional() }, (p) => result('import_image', p, true));
tool('list_captures', 'List completed local screenshots. Unconfirmed human drafts are accessed using status.activeCaptureId.', {}, () => result('list_captures', {}), readOnly);
tool('get_capture', 'Read an editable document and rendered preview. Read again after confirmation because coordinates may be rebased.', { captureId }, (p) => result('get_capture', p, true), readOnly);
tool('annotate', 'Add annotations, update existing objects, or remove object IDs. Each call uses one action and is one undo step. Coordinates are original-image physical pixels. redact is always opaque; mosaic pixelates the base image.', {
  captureId, expectedRevision: revision.optional(), action: z.enum(['add', 'update', 'remove']).default('add'),
  annotations: z.array(annotationSchema).min(1).max(500).optional(),
  id: z.string().min(1).max(120).optional(), patch: patchSchema.optional(), ids: z.array(z.string().min(1).max(120)).min(1).max(500).optional(),
}, (p) => result('annotate', p, true));
tool('crop', 'Set the non-destructive viewport in original-image pixels; annotations do not move. Existing source bounds limit expansion.', { captureId, expectedRevision: revision.optional(), region: regionSchema }, (p) => result('crop', p, true));
for (const name of ['undo', 'redo']) tool(name, `${name} the most recent shared human/agent edit.`, { captureId, expectedRevision: revision.optional() }, (p) => result(name, p, true));
tool('preview', 'Render current crop and annotations for inspection.', { captureId }, (p) => result('preview', p, true), readOnly);
tool('export', 'Export final flattened PNG to an absolute path or managed exports directory. An existing file requires overwrite:true. Does not export the unredacted original.', { captureId, path: z.string().optional(), overwrite: z.boolean().optional() }, (p) => result('export', p), { ...edit, destructiveHint: true });
tool('present', 'Show the screenshot for human editing, reusing its current editor when possible.', { captureId }, (p) => result('present', p));
tool('pin', 'Show a pinned always-on-top screenshot.', { captureId }, (p) => result('pin', p));
tool('copy', 'Copy the rendered PNG to the system clipboard without closing the human editor.', { captureId }, (p) => result('copy', p), { ...edit, destructiveHint: true });
await server.connect(new StdioServerTransport());
