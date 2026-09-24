import test from 'node:test';
import assert from 'node:assert/strict';
import { mountPostingRelease, postingSelectionError } from '../overlay/app/public/toybaco-growth-posting-release.mjs';

function fixture(fetcher) {
  const events = new Map();
  const inputs = [{value:'a',checked:true},{value:'b',checked:false},{value:'c',checked:false}];
  const button = {focus(){this.focused=true;}};
  const status = {focus(){this.focused=true;}};
  const form = {addEventListener(name,fn){events.set(name,fn);},querySelectorAll(){return inputs;}};
  const state = {account_id:42,revision:'c'.repeat(64),limit:2,keep_ids:[],current_ids:['a']};
  const elements = {'#posting-release-form':form,'#posting-release-state':{textContent:JSON.stringify(state)},
    '#posting-release-submit':button,'#posting-release-error':{},'#posting-release-status':status,'#posting-release-refresh':{}};
  mountPostingRelease({querySelector:key=>elements[key]},fetcher,()=> 'd'.repeat(64));
  return {inputs,elements,button,status,change:()=>events.get('change')(),submit:()=>events.get('submit')({preventDefault(){}})};
}
const result = {account_id:42,authority_id:'e'.repeat(64),state:'active',current:true,execute:false,keep_ids:['a','b']};

test('existing resumed selection is retained and over-limit never sends', async()=>{
  const ui=fixture(()=>{assert.fail('over limit must not send');});
  assert.equal(ui.inputs[0].disabled,true);
  ui.inputs[1].checked=true;ui.inputs[2].checked=true;ui.change();
  assert.equal(ui.button.disabled,true);
  assert.match(ui.elements['#posting-release-error'].textContent,/合計2/);
  await ui.submit();
  assert.match(postingSelectionError([],{keep_ids:[],current_ids:['a'],limit:2}),/選んで/);
});

test('one explicit request and no provider submission after success', async()=>{
  const calls=[];let complete;
  const ui=fixture((url,options)=>{calls.push({url,options});return new Promise(resolve=>{complete=resolve;});});
  ui.inputs[1].checked=true;const pending=ui.submit();await ui.submit();
  assert.equal(calls.length,1);assert.ok(ui.inputs.every(input=>input.disabled));
  assert.deepEqual(JSON.parse(calls[0].options.body).integration_ids,['a','b']);
  complete({ok:true,json:async()=>result});await pending;await ui.submit();
  assert.equal(calls.length,1);assert.equal(ui.button.disabled,true);assert.equal(ui.status.focused,true);
  assert.match(ui.status.textContent,/日時と投稿先/);
});

test('response loss retains selection and the exact request id without automatic retry', async()=>{
  const calls=[];const ui=fixture(async(url,options)=>{calls.push(options);throw new Error('response lost');});
  ui.inputs[1].checked=true;await ui.submit();
  assert.equal(calls.length,1);assert.equal(ui.inputs[1].checked,true);assert.equal(ui.button.focused,true);
  await ui.submit();assert.equal(calls[0].body,calls[1].body);assert.equal(calls.length,2);
});

test('stale or foreign success never claims a connection resumed', async()=>{
  for(const value of [{...result,current:false},{...result,account_id:43},{...result,keep_ids:['b']},{...result,execute:true}]) {
    const ui=fixture(async()=>({ok:true,json:async()=>value}));ui.inputs[1].checked=true;await ui.submit();
    assert.equal(ui.status.textContent,'');assert.equal(ui.elements['#posting-release-error'].hidden,false);
    assert.equal(ui.inputs[1].checked,true);
  }
});

test('same connection selection can be explicitly reconfirmed after cancelling an old reservation', async()=>{
  const calls=[];const ui=fixture(async(url,options)=>{calls.push(options);return {ok:true,json:async()=>({...result,keep_ids:['a']})};});
  assert.equal(calls.length,0);assert.equal(ui.button.disabled,false);
  await ui.submit();assert.equal(calls.length,1);
  assert.deepEqual(JSON.parse(calls[0].body).integration_ids,['a']);
  assert.equal(ui.button.disabled,true);assert.match(ui.status.textContent,/日時と投稿先/);
});
