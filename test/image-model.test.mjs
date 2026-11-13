import test from 'node:test';
import assert from 'node:assert/strict';
import { image_create, image_apply, image_finalize } from '../dist/core/core.mjs';
const create=(viewport)=>JSON.parse(image_create(JSON.stringify({width:1200,height:900,...(viewport!==undefined?{viewport}:{})}))).document;
const apply=(document,command,expectedRevision=document.revision)=>{const r=JSON.parse(image_apply(JSON.stringify({document,command,expectedRevision})));assert.equal(r.ok,true,JSON.stringify(r));return r.document;};
const rect={id:'rect-1',type:'rect',x:100,y:150,width:200,height:90,color:'#ff00AA',stroke:3,opacity:1};
test('image document shares additive edits, non-destructive crop and one revision history',()=>{
 let d=create(null);d=apply(d,{type:'crop',rect:{x:30,y:20,width:500,height:400}});d=apply(d,{type:'add',annotations:[rect]});d=apply(d,{type:'move',id:rect.id,dx:25,dy:30});assert.equal(d.annotations[0].x,125);
 d=apply(d,{type:'crop',rect:{x:90,y:100,width:50,height:50}});assert.equal(d.annotations[0].width,200);
 d=apply(d,{type:'undo'});assert.equal(d.viewport.width,500);d=apply(d,{type:'undo'});assert.equal(d.annotations[0].x,100);d=apply(d,{type:'redo'});assert.equal(d.annotations[0].x,125);
 const conflict=JSON.parse(image_apply(JSON.stringify({document:d,command:{type:'remove',ids:[rect.id]},expectedRevision:0})));assert.equal(conflict.error.code,'revision_conflict');
 d=apply(d,{type:'update',id:rect.id,patch:{color:'#00ff00'}});assert.equal(d.redo.length,0);
});
test('freehand large histories cross old 64KiB boundary and retain immutable snapshots',()=>{
 let d=create();const points=Array.from({length:2000},(_,i)=>({x:i%1000,y:Math.floor(i/10)%800}));d=apply(d,{type:'add',annotations:[{id:'stroke',type:'marker',x:0,y:0,points,color:'#ffbb00',stroke:24,opacity:.3}]});
 for(let i=0;i<5;i++)d=apply(d,{type:'move',id:'stroke',dx:1,dy:1});assert.ok(JSON.stringify(d).length>65536);const restored=apply(d,{type:'undo'});assert.equal(restored.annotations[0].points[0].x,4);assert.equal(d.annotations[0].points[0].x,5);
});
test('completion rebases editable objects and clears histories that depend on discarded pixels',()=>{
 let d=apply(create(),{type:'add',annotations:[rect]});d=apply(d,{type:'crop',rect:{x:80,y:120,width:200,height:200}});const r=JSON.parse(image_finalize(JSON.stringify({document:d})));assert.equal(r.ok,true);assert.equal(r.document.width,200);assert.equal(r.document.annotations[0].x,20);assert.equal(r.document.annotations[0].y,30);assert.equal(r.document.viewport.x,0);assert.equal(r.document.undo.length,0);assert.equal(r.document.revision,d.revision+1);
});
test('history is bounded to 100 and deletion is an atomic undoable operation',()=>{
 let d=apply(create(),{type:'add',annotations:[rect,{...rect,id:'rect-2'}]});for(let i=0;i<105;i++)d=apply(d,{type:'move',id:rect.id,dx:1,dy:0});assert.equal(d.undo.length,100);d=apply(d,{type:'remove',ids:['rect-1','rect-2']});assert.equal(d.annotations.length,0);d=apply(d,{type:'undo'});assert.equal(d.annotations.length,2);
});
test('invalid styles, unsupported objects and duplicate annotation IDs are rejected',()=>{
 const d=create();for(const bad of [{...rect,color:'#zzzzzz'},{...rect,width:-1},{...rect,opacity:2},{...rect,type:'unknown'}])assert.equal(JSON.parse(image_apply(JSON.stringify({document:d,command:{type:'add',annotations:[bad]}}))).ok,false);
 const d2=apply(d,{type:'add',annotations:[rect]});assert.equal(JSON.parse(image_apply(JSON.stringify({document:d2,command:{type:'add',annotations:[rect]}}))).error.code,'duplicate_id');
 const solid=apply(d,{type:'add',annotations:[{...rect,type:'redact',opacity:.2}]});assert.equal(solid.annotations[0].opacity,1);
});
