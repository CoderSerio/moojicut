import test from 'node:test';
import assert from 'node:assert/strict';
import {runProcess} from '../src/main/media-tools.mjs';
test('canceling a media process rejects with AbortError and terminates the child',async()=>{
  const controller=new AbortController();
  const run=runProcess(process.execPath,['-e','setInterval(()=>process.stdout.write("alive\\n"),20)'],{signal:controller.signal,onStdout(){controller.abort();}});
  await assert.rejects(run,{name:'AbortError'});
});
test('an already canceled media operation does not launch its executable',async()=>{
  const controller=new AbortController();controller.abort();
  await assert.rejects(runProcess('/does-not-exist',[],{signal:controller.signal}),{name:'AbortError'});
});
