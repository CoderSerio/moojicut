import { $, action, notice, number, view } from './shared-ui.mjs';
import { cropRect } from './core-bridge.mjs';

export function createImageEditor({ api }) {
  const canvas = $('image-canvas');
  const context = canvas.getContext('2d');
  let baseImage = null;
  let annotations = [];
  let undoStack = [];
  let tool = 'rectangle';
  let drawing = null;
  let selection = null;

  function openImage(image) {
    baseImage = image;
    annotations = [];
    undoStack = [];
    selection = null;
    drawing = null;
    $('apply-crop').hidden = true;
    view('image');
    renderImage();
  }

  function rememberImage() {
    undoStack.push({ baseImage, annotations: [...annotations] });
    if (undoStack.length > 20) undoStack.shift();
  }

  function paintAnnotation(ctx, item) {
    ctx.save();
    ctx.strokeStyle = item.color;
    ctx.fillStyle = item.color;
    ctx.lineWidth = item.stroke;
    ctx.lineJoin = 'round';
    ctx.lineCap = 'round';
    const dx = item.x2 - item.x1;
    const dy = item.y2 - item.y1;
    if (item.tool === 'rectangle') ctx.strokeRect(item.x1, item.y1, dx, dy);
    if (item.tool === 'redact') { ctx.fillStyle = '#111111'; ctx.fillRect(item.x1, item.y1, dx, dy); }
    if (item.tool === 'text') {
      ctx.font = `600 ${Math.max(18, item.stroke * 6)}px sans-serif`;
      ctx.textBaseline = 'top';
      ctx.fillText(item.text, item.x1, item.y1);
    }
    if (item.tool === 'arrow') {
      const angle = Math.atan2(dy, dx);
      const head = Math.max(12, item.stroke * 4);
      ctx.beginPath(); ctx.moveTo(item.x1, item.y1); ctx.lineTo(item.x2, item.y2);
      ctx.moveTo(item.x2 - head * Math.cos(angle - Math.PI / 6), item.y2 - head * Math.sin(angle - Math.PI / 6));
      ctx.lineTo(item.x2, item.y2);
      ctx.lineTo(item.x2 - head * Math.cos(angle + Math.PI / 6), item.y2 - head * Math.sin(angle + Math.PI / 6));
      ctx.stroke();
    }
    ctx.restore();
  }

  function renderImage(includeSelection = true) {
    if (!baseImage) return;
    canvas.width = baseImage.width;
    canvas.height = baseImage.height;
    context.drawImage(baseImage, 0, 0);
    for (const item of annotations) paintAnnotation(context, item);
    if (drawing && drawing.tool !== 'crop') paintAnnotation(context, drawing);
    const crop = drawing?.tool === 'crop' ? drawing : selection;
    if (includeSelection && crop) {
      context.save();
      context.strokeStyle = '#ffffff'; context.lineWidth = 2; context.setLineDash([8, 6]);
      context.strokeRect(crop.x1, crop.y1, crop.x2 - crop.x1, crop.y2 - crop.y1);
      context.restore();
    }
    $('undo-image').disabled = !undoStack.length;
  }

  function canvasPoint(event) {
    const rect = canvas.getBoundingClientRect();
    return { x: Math.round(Math.max(0, Math.min(canvas.width, (event.clientX - rect.left) * canvas.width / rect.width))), y: Math.round(Math.max(0, Math.min(canvas.height, (event.clientY - rect.top) * canvas.height / rect.height))) };
  }

  for (const button of document.querySelectorAll('[data-tool]')) button.addEventListener('click', () => {
    tool = button.dataset.tool;
    for (const other of document.querySelectorAll('[data-tool]')) other.setAttribute('aria-pressed', String(other === button));
    selection = null;
    $('apply-crop').hidden = true;
    renderImage();
  });

  canvas.addEventListener('pointerdown', (event) => {
    if (!baseImage || event.button !== 0) return;
    const { x, y } = canvasPoint(event);
    const item = { tool, x1: x, y1: y, x2: x, y2: y, color: $('color').value, stroke: Math.max(1, Math.min(24, number('stroke') || 4)) };
    if (tool === 'text') {
      item.text = $('annotation-text').value.trim();
      if (!item.text) { notice('请先在工具栏输入标注文字。'); return; }
      rememberImage(); annotations.push(item); renderImage(); return;
    }
    drawing = item;
    canvas.setPointerCapture(event.pointerId);
  });

  canvas.addEventListener('pointermove', (event) => {
    if (!drawing) return;
    const { x, y } = canvasPoint(event);
    drawing.x2 = x; drawing.y2 = y;
    renderImage();
  });

  canvas.addEventListener('pointerup', (event) => {
    if (!drawing) return;
    const { x, y } = canvasPoint(event);
    drawing.x2 = x; drawing.y2 = y;
    if (Math.abs(drawing.x2 - drawing.x1) + Math.abs(drawing.y2 - drawing.y1) > 2) {
      if (drawing.tool === 'crop') { selection = drawing; $('apply-crop').hidden = false; }
      else { rememberImage(); annotations.push(drawing); }
    }
    drawing = null;
    renderImage();
  });
  canvas.addEventListener('pointercancel', () => { drawing = null; renderImage(); });

  $('undo-image').addEventListener('click', () => {
    const state = undoStack.pop();
    if (!state) return;
    baseImage = state.baseImage;
    annotations = state.annotations;
    selection = null;
    $('apply-crop').hidden = true;
    renderImage();
  });

  action('apply-crop', () => {
    if (!selection) return;
    const rect = cropRect({ sourceWidth: canvas.width, sourceHeight: canvas.height, x: Math.min(selection.x1, selection.x2), y: Math.min(selection.y1, selection.y2), width: Math.abs(selection.x2 - selection.x1), height: Math.abs(selection.y2 - selection.y1) }).rect;
    rememberImage();
    renderImage(false);
    const cropped = document.createElement('canvas');
    cropped.width = rect.width; cropped.height = rect.height;
    cropped.getContext('2d').drawImage(canvas, rect.x, rect.y, rect.width, rect.height, 0, 0, rect.width, rect.height);
    baseImage = cropped; annotations = []; selection = null;
    $('apply-crop').hidden = true;
    renderImage();
  });

  async function imageBytes() {
    renderImage(false);
    try {
      const blob = await new Promise((resolve, reject) => canvas.toBlob((value) => value ? resolve(value) : reject(new Error('无法生成图片。')), 'image/png'));
      return new Uint8Array(await blob.arrayBuffer());
    } finally { renderImage(); }
  }
  action('save-image', async () => { const result = await api.saveImage(await imageBytes()); if (result) notice('PNG 已保存。'); });
  action('copy-image', async () => { await api.copyImage(await imageBytes()); notice('图片已复制，可以直接粘贴到聊天窗口。'); });

  return { open: openImage };
}
