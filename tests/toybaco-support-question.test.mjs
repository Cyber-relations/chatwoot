import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
const source = readFileSync(new URL('../overlay/app/app/javascript/dashboard/helper/toybacoSupportQuestion.js', import.meta.url), 'utf8');
const { createSupportQuestion } = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
const article = { id: 'reply', title: '返信', answer: '確認済みの説明', action: 'conversations' };
function fixture() {
  const state = {};
  const current = { accountId: '4', enabled: true, version: 'test', articles: [article] };
  const calls = [];
  const pending = [];
  const api = createSupportQuestion({context:()=>current, change: v=>Object.assign(state,v), request:(...args)=>{
    calls.push(args);return new Promise(resolve=>pending.push(resolve));
  }});
  const respond=(data, status=200)=>pending.shift()({ok:status===200,status,json:async()=>data});
  const data = {account_id:4,version:'test',article:{id:'reply',answer:'untrusted replacement',action:'external_send'}};
  return {api,state,current,calls,respond,data};
}
test('only an existing article supplies text and action, with no paid AI request',async()=>{
  const f=fixture(); const work=f.api.ask('返信する場所は？');
  f.respond(f.data);await work;
  assert.equal(f.state.article,article);
  assert.equal(f.calls[0][0],'/toybaco/support');
  assert.deepEqual(JSON.parse(f.calls[0][1].body),{account_id:'4',support_question:'返信する場所は？'});
  assert.equal(f.calls[0][1].credentials,'same-origin');
});
test('cancel and store switch suppress delayed answers',async()=>{
  for(const cancel of [true,false]) {
    const f=fixture(); const work=f.api.ask('返信したい');
    if(cancel)f.api.cancel();else f.current.accountId='5';
    f.respond(f.data);await work;
    assert.equal(f.state.article,null);
  }
});
test('duplicate clicks do not start concurrent model requests',async()=>{
  const f=fixture();const work=f.api.ask('返信したい');await f.api.ask('もう一度');
  assert.equal(f.calls.length,1);f.respond(f.data);await work;
});
test('stale versions and invented article IDs do not suggest actions',async()=>{
  for(const data of [{version:'old',account_id:4,article:{id:'reply'}},{version:'test',account_id:4,article:{id:'delete_account'}}]) {
    const f=fixture();const work=f.api.ask('消したい');f.respond(data);await work;
    assert.equal(f.state.article,null);assert.ok(f.state.error);
  }
});
test('overload keeps static help intact and reports a bounded retry time',async()=>{
  const f=fixture();const work=f.api.ask('返信したい');
  const before=Date.now();f.respond({error:'手順の検索は続けられます。',retry_after:60},429);await work;
  assert.equal(f.state.busy,false);assert.ok(f.state.retryAt>=before+60000);
  assert.deepEqual(f.current.articles,[article]);
});

const { createSupportDiagnostics, supportGuideStep, supportGuideArticles } = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
test('diagnostics discard stale store/topic results and reject unbounded checks', async()=>{
  for (const change of ['store','topic','too_many']) {
    const current={enabled:true,accountId:'4',articleId:'reply',version:'test'};
    const state={};let respond;
    const api=createSupportDiagnostics({context:()=>current,change:v=>Object.assign(state,v),request:()=>new Promise(resolve=>{respond=resolve;})});
    const work=api.inspect();
    if(change==='store')current.accountId='5';
    if(change==='topic')current.articleId='line';
    respond({ok:true,json:async()=>({account_id:4,article_id:'reply',version:'test',checks:Array.from({length:change==='too_many'?4:1},()=>({id:'account',state:'ok',text:'確認済み'}))})});
    await work;assert.deepEqual(state.checks,[]);
    if(change==='too_many')assert.ok(state.error);
  }
});
test('diagnostics are an explicit read-only request and keep the original response text',async()=>{
  const state={};let call;
  const checks=[{id:'inboxes',state:'information',text:'設定があります。実受信は受信箱で確認してください。'}];
  const api=createSupportDiagnostics({context:()=>({enabled:true,accountId:'4',articleId:'reply',version:'test'}),change:v=>Object.assign(state,v),request:async(...args)=>{
    call=args;return {ok:true,json:async()=>({account_id:4,article_id:'reply',version:'test',checks})};
  }});
  assert.equal(call,undefined);await api.inspect();assert.deepEqual(state.checks,checks);
  assert.match(call[0],/^\/toybaco\/support\/diagnostics\?/);
  assert.equal(call[1].cache,'no-store');assert.equal(call[1].body,undefined);
});
test('support guides select only registered actions and cannot mutate the registry',()=>{
  assert.equal(supportGuideStep('constructor'),null);
  assert.equal(supportGuideStep('external-send'),null);
  assert.deepEqual(supportGuideStep('reply'),['reply.editor','ここに返信を入力してください。']);
  supportGuideStep('reply')[0]='reply.send';
  assert.equal(supportGuideStep('reply')[0],'reply.editor');
  assert.ok(supportGuideArticles().includes('ai'));
});
