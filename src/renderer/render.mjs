import { loadSource, renderDocument, pngBytes } from './image-render.mjs';
window.renderMooncap = async (document, url) => Array.from(await pngBytes(renderDocument(document, await loadSource(url))));
window.mooncapRenderReady = Promise.resolve();
