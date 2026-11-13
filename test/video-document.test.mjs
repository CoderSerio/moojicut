import test from 'node:test';
import assert from 'node:assert/strict';
import { video_open, video_command, video_snapshot, video_seek, video_dispose, edit_plan } from '../dist/core/core.mjs';
import { recordingRegion } from '../src/renderer/recording-region.mjs';
const source={durationMs:10000,width:1920,height:1080,hasAudio:true};
const read=(value)=>{const result=JSON.parse(value);assert.equal(result.ok,true,JSON.stringify(result));return result;};
const command=(session,value)=>read(video_command(session,JSON.stringify(value)));

test('MoonBit keeps overlapping deletions in source order across trim changes and undo',()=>{
  let state=read(video_open(JSON.stringify(source),''));
  const id=state.session;
  try{
    state=command(id,{type:'cut',cut:{startMs:4000,endMs:6000}});
    state=command(id,{type:'cut',cut:{startMs:2000,endMs:4500}});
    state=command(id,{type:'cut',cut:{startMs:6000,endMs:7000}});
    assert.deepEqual(state.plan.segments.map(x=>[x.sourceStartMs,x.sourceEndMs]),[[0,2000],[7000,10000]]);
    state=command(id,{type:'trim',trim:{startMs:3000,endMs:9000}});
    assert.deepEqual(state.plan.segments.map(x=>[x.sourceStartMs,x.sourceEndMs]),[[7000,9000]]);
    state=command(id,{type:'trim',trim:{startMs:0,endMs:10000}});
    assert.equal(state.plan.outputDurationMs,5000);
    const before=state.document;
    assert.equal(JSON.parse(video_command(id,JSON.stringify({type:'cut',cut:{startMs:0,endMs:10000}}))).error.code,'empty_output');
    assert.deepEqual(read(video_snapshot(id)).document,before,'invalid destructive edits must not mutate current document/history');
    state=command(id,{type:'undo'});assert.equal(state.plan.outputDurationMs,2000);
    state=command(id,{type:'redo'});assert.equal(state.plan.outputDurationMs,5000);
    state=command(id,{type:'undo'});state=command(id,{type:'mute',muted:true});assert.equal(state.canRedo,false);
  }finally{video_dispose(id);}
});

test('video crop normalization, output clock, draft re-open and reset preserve source',()=>{
  let state=read(video_open(JSON.stringify(source),''));const id=state.session;
  try{
    state=command(id,{type:'crop',crop:{x:11,y:17,width:501,height:301}});
    assert.deepEqual(state.document.crop,{x:11,y:17,width:500,height:300});
    state=command(id,{type:'cut',cut:{startMs:2000,endMs:5000}});
    assert.deepEqual(read(video_seek(id,3000)),{ok:true,sourceMs:5000,outputMs:2000,atEnd:false});
    assert.equal(read(video_seek(id,6000)).outputMs,3000);
    assert.equal(read(video_seek(id,10000)).atEnd,true);
    const draft=state.document;
    const opened=read(video_open(JSON.stringify(source),JSON.stringify({...draft,source:{...source,width:99}})));
    assert.equal(opened.document.source.width,1920);
    assert.deepEqual(opened.plan,state.plan);video_dispose(opened.session);
    state=command(id,{type:'reset'});assert.equal(state.document.crop,null);assert.equal(state.plan.outputDurationMs,10000);
    state=command(id,{type:'undo'});assert.deepEqual(state.document,draft);
  }finally{video_dispose(id);}
});

test('legacy cut plus multiple cuts and malformed requests are checked by the core',()=>{
  const result=read(edit_plan(JSON.stringify({durationMs:10000,trim:{startMs:0,endMs:10000},cut:{startMs:1000,endMs:2000},cuts:[{startMs:6000,endMs:7000},{startMs:2000,endMs:3000}]})));
  assert.equal(result.outputDurationMs,7000);
  assert.deepEqual(result.segments.map(x=>[x.sourceStartMs,x.sourceEndMs]),[[0,1000],[3000,6000],[7000,10000]]);
  assert.equal(JSON.parse(edit_plan(JSON.stringify({durationMs:10000,trim:{startMs:0,endMs:10000},cuts:[{startMs:1,endMs:Infinity}]}))).ok,false);
});

test('region capture scales source coordinates to delivered frames and never includes the full display',()=>{
  assert.deepEqual(recordingRegion({sourceWidth:2560,sourceHeight:1440,region:{x:100,y:200,width:800,height:600}},1280,720),{x:50,y:100,width:400,height:300});
  assert.throws(()=>recordingRegion({sourceWidth:1920,sourceHeight:1080,region:{x:1800,y:0,width:400,height:200}},1920,1080),/超出/);
});
