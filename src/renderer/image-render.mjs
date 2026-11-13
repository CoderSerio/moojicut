// Browser canvas adapter. Geometry and document edits belong to the MoonBit reducer.
export async function loadSource(url) {
  const image = new Image(); image.src = url; await image.decode(); return image;
}
export function textLayout(item, context) {
  context.font = `${item.bold ? 700 : 400} ${item.fontSize || 24}px system-ui, sans-serif`;
  const width = Math.max(1, item.width), lines = [];
  for (const paragraph of String(item.text || '').split('\n')) {
    let line = '';
    const chars = typeof Intl.Segmenter === 'function' ? [...new Intl.Segmenter(undefined, { granularity: 'grapheme' }).segment(paragraph)].map(x => x.segment) : [...paragraph];
    for (const char of chars) {
      if (line && context.measureText(line + char).width > width) { lines.push(line); line = char; }
      else line += char;
    }
    lines.push(line);
  }
  const metrics = context.measureText('国Mg');
  const lineHeight = Math.max((item.fontSize || 24) * 1.3, (metrics.actualBoundingBoxAscent || 0) + (metrics.actualBoundingBoxDescent || 0));
  return { lines, lineHeight, height: Math.max(lineHeight, lines.length * lineHeight) };
}
export function bounds(item, context) {
  if (item.type === 'text') return { x:item.x,y:item.y,width:item.width,height:textLayout(item,context).height };
  if (item.type === 'arrow') return { x:Math.min(item.x,item.x2),y:Math.min(item.y,item.y2),width:Math.abs(item.x2-item.x),height:Math.abs(item.y2-item.y) };
  if (item.points) { const xs=item.points.map(p=>p.x),ys=item.points.map(p=>p.y); return {x:Math.min(...xs),y:Math.min(...ys),width:Math.max(...xs)-Math.min(...xs),height:Math.max(...ys)-Math.min(...ys)}; }
  return {x:item.x,y:item.y,width:item.width,height:item.height};
}
export function annotationPath(item) {
  const p = new Path2D();
  if (item.type==='rect'||item.type==='redact'||item.type==='mosaic') p.rect(item.x,item.y,item.width,item.height);
  if (item.type==='ellipse') p.ellipse(item.x+item.width/2,item.y+item.height/2,item.width/2,item.height/2,0,0,Math.PI*2);
  if (item.type==='arrow') { p.moveTo(item.x,item.y);p.lineTo(item.x2,item.y2); }
  if (item.points?.length) { p.moveTo(item.points[0].x,item.points[0].y);for(const point of item.points.slice(1))p.lineTo(point.x,point.y); }
  return p;
}
export function paintAnnotation(context,item) {
  context.save();context.strokeStyle=item.color;context.fillStyle=item.color;context.lineWidth=item.stroke||3;
  context.lineJoin='round';context.lineCap='round';context.globalAlpha=item.opacity??1;
  if(item.dash)context.setLineDash([context.lineWidth*3,context.lineWidth*2]);
  if(item.type==='text') {
    const layout=textLayout(item,context);context.textBaseline='top';context.textAlign=item.align||'left';
    const x=item.x+(item.align==='center'?item.width/2:item.align==='right'?item.width:0);
    layout.lines.forEach((line,i)=>context.fillText(line,x,item.y+i*layout.lineHeight));
  } else {
    const p=annotationPath(item);
    if(item.fill||item.type==='redact')context.fill(p);else context.stroke(p);
    if(item.type==='arrow') {
      context.setLineDash([]);const angle=Math.atan2(item.y2-item.y,item.x2-item.x),length=Math.max(12,context.lineWidth*4);
      const tip=(x,y,a)=>{context.beginPath();context.moveTo(x,y);context.lineTo(x-length*Math.cos(a-.45),y-length*Math.sin(a-.45));context.lineTo(x-length*Math.cos(a+.45),y-length*Math.sin(a+.45));context.closePath();context.fill();};
      if(item.arrowHead!=='none')tip(item.x2,item.y2,angle);
      if(item.arrowHead==='both')tip(item.x,item.y,angle+Math.PI);
    }
  }
  context.restore();
}
export function paintDocument(context,doc,source) {
  context.drawImage(source,0,0,doc.width,doc.height);
  for(const item of doc.annotations.filter(a=>a.type==='mosaic')) {
    const v=doc.viewport||{x:0,y:0,width:doc.width,height:doc.height};
    const x=Math.max(0,v.x,item.x),y=Math.max(0,v.y,item.y),w=Math.min(doc.width,v.x+v.width,item.x+item.width)-x,h=Math.min(doc.height,v.y+v.height,item.y+item.height)-y;
    if(w<=0||h<=0)continue;
    const temp=document.createElement('canvas'),block=item.blockSize||12;temp.width=Math.max(1,Math.ceil(w/block));temp.height=Math.max(1,Math.ceil(h/block));
    temp.getContext('2d').drawImage(source,x,y,w,h,0,0,temp.width,temp.height);
    context.save();context.imageSmoothingEnabled=false;context.drawImage(temp,0,0,temp.width,temp.height,x,y,w,h);context.restore();
  }
  for(const item of doc.annotations.filter(a=>a.type==='redact'))paintAnnotation(context,{...item,opacity:1});
  for(const item of doc.annotations.filter(a=>!['redact','mosaic'].includes(a.type)))paintAnnotation(context,item);
}
const croppedSources=new WeakMap();
export function renderDocument(doc,source) {
  const v=doc.viewport||{x:0,y:0,width:doc.width,height:doc.height};
  const canvas=document.createElement('canvas');canvas.width=v.width;canvas.height=v.height;
  let base=source,projected=doc;
  if(v.x||v.y||v.width!==doc.width||v.height!==doc.height){
    const key=[v.x,v.y,v.width,v.height].join(',');let cached=croppedSources.get(source);
    if(!cached||cached.key!==key){const crop=document.createElement('canvas');crop.width=v.width;crop.height=v.height;crop.getContext('2d').drawImage(source,v.x,v.y,v.width,v.height,0,0,v.width,v.height);cached={key,canvas:crop};croppedSources.set(source,cached);}
    base=cached.canvas;
    // Project before rasterization, just like image_finalize. This avoids tiny
    // font/path antialias differences between a canvas transform and a reopened document.
    projected={...doc,width:v.width,height:v.height,viewport:{x:0,y:0,width:v.width,height:v.height},annotations:doc.annotations.map(a=>({...a,x:a.x-v.x,y:a.y-v.y,...(a.x2!==undefined?{x2:a.x2-v.x,y2:a.y2-v.y}:{}),...(a.points?{points:a.points.map(p=>({x:p.x-v.x,y:p.y-v.y}))}:{})}))};
  }
  paintDocument(canvas.getContext('2d'),projected,base);
  return canvas;
}
export async function pngBytes(canvas) {
  const blob=await new Promise((resolve,reject)=>canvas.toBlob(blob=>blob?resolve(blob):reject(new Error('无法生成 PNG')),'image/png'));
  return new Uint8Array(await blob.arrayBuffer());
}
export function hitObjects(doc,point,context,tolerance=6) {
  const ordered=[...doc.annotations.filter(a=>a.type==='mosaic'),...doc.annotations.filter(a=>a.type==='redact'),...doc.annotations.filter(a=>!['mosaic','redact'].includes(a.type))];
  return ordered.reverse().filter(a=>{
    if(a.type==='text'){const b=bounds(a,context);return point.x>=b.x&&point.x<=b.x+b.width&&point.y>=b.y&&point.y<=b.y+b.height;}
    const p=annotationPath(a);context.save();context.lineWidth=(a.stroke||3)+tolerance*2;context.lineCap='round';context.lineJoin='round';
    const hit=context.isPointInStroke(p,point.x,point.y)||((a.fill||a.type==='redact'||a.type==='mosaic')&&context.isPointInPath(p,point.x,point.y));context.restore();return hit;
  });
}
