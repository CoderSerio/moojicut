import { z } from 'zod';
export const captureId = z.string().uuid();
export const revision = z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER);
const coordinate = z.number().finite().min(-1_000_000).max(1_000_000);
export const regionSchema = z.object({ x: z.number().int().min(0), y: z.number().int().min(0), width: z.number().int().min(1).max(32768), height: z.number().int().min(1).max(32768) }).strict();
export const annotationSchema = z.object({
  id: z.string().min(1).max(120).optional(),
  type: z.enum(['rect', 'ellipse', 'arrow', 'pencil', 'marker', 'redact', 'mosaic', 'text']),
  x: coordinate, y: coordinate,
  width: z.number().finite().positive().max(65536).optional(), height: z.number().finite().positive().max(65536).optional(),
  x2: coordinate.optional(), y2: coordinate.optional(),
  points: z.array(z.object({ x: coordinate, y: coordinate }).strict()).min(2).max(8192).optional(),
  color: z.string().regex(/^#[0-9a-fA-F]{6}$/).optional(),
  stroke: z.number().finite().min(1).max(128).optional(), opacity: z.number().min(0.01).max(1).optional(),
  fill: z.boolean().optional(), dash: z.boolean().optional(), arrowHead: z.enum(['none', 'end', 'both']).optional(),
  fontSize: z.number().finite().min(8).max(128).optional(), bold: z.boolean().optional(), align: z.enum(['left', 'center', 'right']).optional(),
  text: z.string().max(10_000).optional(), blockSize: z.number().int().min(4).max(48).optional(),
}).strict();
export const patchSchema = annotationSchema.partial().omit({ id: true, type: true });
