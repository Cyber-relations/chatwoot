import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';

const root = path.resolve(process.argv[2] || path.join(import.meta.dirname, '..'));
assert.ok(process.argv[3], 'The required gate must pass its exact patched upstream source for caller integration');
const actualRoot = path.resolve(process.argv[3]);
const readActual = name => fs.readFileSync(path.join(actualRoot, name), 'utf8');
const source = fs.readFileSync(path.join(root, 'overlay/app/app/javascript/widget/helpers/httpSession.js'), 'utf8')
  .replaceAll('export const ', 'const ');

const fixture = ({ persisted = true, wrongReadback = false, fail = false, standalone = false } = {}) => {
  const listeners = new Set(); const timers = new Map(); const intervals = new Map();
  const sent = []; const calls = []; let nextId = 0;
  const parent = { postMessage: (data, origin) => sent.push({ data: JSON.parse(data.slice('chatwoot-widget:'.length)), origin }) };
  const state = { location: { origin: 'https://app.example.test', href: 'https://app.example.test/widget?website_token=public&toybaco_sdk=2' },
    chatwootWebChannel: { websiteToken: 'public' }, toybacoHttpSessionRequested: true,
    addEventListener: (type, fn) => { assert.equal(type, 'message'); listeners.add(fn); },
    removeEventListener: (type, fn) => listeners.delete(fn) };
  state.parent = standalone ? state : parent;
  const context = { window: state, crypto: { getRandomValues: bytes => bytes.fill(7) }, Uint8Array, URL,
    setTimeout: fn => { const id = ++nextId; timers.set(id, fn); return id; }, clearTimeout: id => timers.delete(id),
    setInterval: fn => { const id = ++nextId; intervals.set(id, fn); return id; }, clearInterval: id => intervals.delete(id),
    document: { getElementById: () => ({ textContent: '' }) },
    fetch: async (url, options) => {
      calls.push({ url: url.toString(), ...options });
      if (fail) throw new Error('Synthetic unavailable transport');
      if (options.method === 'GET') return { ok: persisted, json: async () => ({ persisted: !wrongReadback, proof: 'tbwp1.new' }) };
      if (new URL(url).pathname.endsWith('/recover')) return { ok: true, json: async () => ({ persisted: false, proof: 'tbwr1.synthetic' }) };
      return { ok: true, json: async () => ({ issued: true, proof: 'tbwp1.initial', recovery_code: 'c'.repeat(64) }) };
    },
  };
  vm.runInNewContext(`${source}\nthis.bootstrap = bootstrapHttpSession; this.install = installHttpHandoffReceiver;`, context);
  const start = context.bootstrap();
  const respond = overrides => {
    const challenge = sent.find(item => item.data.event === 'http-session-inert')?.data;
    const event = { source: parent, origin: 'https://shop.example.test',
      data: `chatwoot-widget:${JSON.stringify({ event: 'http-session-input', requestId: challenge?.requestId, token: 'old-synthetic-proof' })}`, ...overrides };
    for (const fn of [...listeners]) fn(event);
  };
  return { context, start, respond, state, calls, sent, timers, listeners, intervals, parent };
};

const saved = fixture();
assert.equal(saved.calls.length, 0, 'No identity or API action before the parent proof handshake');
const challenge = saved.sent[0];
assert.equal(challenge.origin, '*', 'Only the public nonce challenge may use an unknown parent origin');
assert.deepEqual(Object.keys(challenge.data).sort(), ['event', 'popout', 'requestId']);
for (const override of [{ source: {} }, { origin: 'null' }, { data: 'chatwoot-widget:null' },
  { data: 'chatwoot-widget:{"event":"http-session-input","requestId":"wrong","token":"foreign"}' }]) saved.respond(override);
assert.equal(saved.calls.length, 0, 'Wrong window, opaque origin and wrong request cannot select a visitor');
saved.respond();
await saved.start;
assert.equal(saved.calls.length, 2);
assert.ok(saved.calls.every(call => !call.url.includes('old-synthetic-proof') && !call.url.includes('cw_conversation')));
assert.equal(JSON.parse(saved.calls[0].body).legacy_token, 'old-synthetic-proof');
assert.equal(saved.calls[0].credentials, 'same-origin');
assert.equal(saved.calls[1].headers['X-Toybaco-Widget'], '1');
assert.equal(saved.calls[1].headers['X-Auth-Token'], 'tbwp1.initial');
assert.equal(saved.state.authToken, 'tbwp1.new');
assert.equal(saved.state.toybacoWidgetParentOrigin, 'https://shop.example.test');
assert.equal(saved.sent.at(-1).data.persisted, true);
assert.equal(saved.sent.at(-1).origin, 'https://shop.example.test');
assert.equal(saved.listeners.size, 0);
assert.equal(saved.intervals.size, 0);
assert.equal(saved.timers.size, 0);
assert.ok(!JSON.stringify(saved.sent).includes('old-synthetic-proof'), 'No reusable visitor proof sent back to parent');

for (const mode of [{ persisted: false }, { wrongReadback: true }]) {
  const denied = fixture(mode); denied.respond(); await denied.start;
  assert.equal(denied.calls.length, 3);
  assert.ok(denied.calls[2].url.includes('/recover'));
  assert.equal(denied.state.authToken, 'tbwr1.synthetic');
  assert.equal(denied.sent.at(-1).data.persisted, false, 'Cookie rejection/missing readback never claims persistence');
}

const unavailable = fixture({ fail: true }); unavailable.respond();
await assert.rejects(unavailable.start, /unavailable/);
assert.equal(unavailable.state.toybacoHttpSession, undefined);
assert.equal(unavailable.sent.some(item => item.data.event === 'http-session-ready'), false);

const timeout = fixture();
for (const fn of [...timeout.timers.values()]) fn();
await assert.rejects(timeout.start, /timed out/);
assert.equal(timeout.calls.length, 0);
assert.equal(timeout.listeners.size, 0);
assert.equal(timeout.intervals.size, 0);

const alone = fixture({ standalone: true }); await alone.start;
assert.equal(JSON.parse(alone.calls[0].body).legacy_token, null);
assert.equal(alone.state.toybacoWidgetParentOrigin, 'https://app.example.test');

// Pin the actual browser entrypoints and transport callers, rather than treating
// helper-only tests as the whole product's acceptance.
const read = name => fs.readFileSync(path.join(root, name), 'utf8');
const entry = read('overlay/app/app/javascript/entrypoints/widget.js');
assert.ok(entry.indexOf('await bootstrapHttpSession()') < entry.indexOf("app.mount('#app')"));
assert.ok(entry.includes('tbwhttp1.${window.chatwootWebChannel.websiteToken}.${window.authToken}'));
assert.ok(read('overlay/app/app/javascript/widget/components/ChatAttachment.vue').includes("xhr.setRequestHeader('X-Toybaco-Widget', '1')"));
assert.ok(read('overlay/app/app/javascript/widget/store/modules/contacts.js').includes("sendMessage({ event: 'http-session-identity-changed' })"));
assert.ok(read('overlay/app/app/javascript/widget/helpers/IframeEventHelper.js').includes('window.toybacoHttpSession ? undefined : window.authToken'));
assert.ok(read('overlay/app/app/javascript/widget/helpers/utils.js').includes('window.toybacoWidgetParentOrigin'));
console.log('Widget HTTP session actual bootstrap: no early identity, exact parent/challenge, body-only legacy proof, cookie readback, bounded nonpersistent recovery and timeout PASS');

const axiosSource = read('overlay/app/app/javascript/widget/helpers/axios.js')
  .replace(/^import [^\n]+\n/gm, '').replaceAll('export const ', 'const ');
let acceptResponse; let rejectResponse; let prepareRequest;
const refreshes = []; const retries = []; const proofEvents = [];
const actualClient = { defaults: { headers: { common: {} } },
  interceptors: { request: { use: fn => { prepareRequest = fn; } }, response: { use: (success, failed) => { acceptResponse = success; rejectResponse = failed; } } },
  post: async (...args) => { refreshes.push(args); return { data: { proof: 'tbwp1.renewed' } }; },
  request: async config => { retries.push(config); return { config }; },
};
const axiosContext = { axios: { create: () => actualClient }, APP_BASE_URL: '', URLSearchParams,
  stripWidgetSessionQuery: value => value, Event: class { constructor(type) { this.type = type; } },
  window: { authToken: 'tbwp1.expired', chatwootWebChannel: { websiteToken: 'public' }, dispatchEvent: event => proofEvents.push(event.type) } };
vm.runInNewContext(`${axiosSource}\nthis.transportSetHeader = setHeader;`, axiosContext);
const body = { content: 'Synthetic unchanged intent' };
const expired = () => ({ response: { status: 401, data: { error: 'widget_proof_expired' } },
  config: prepareRequest({ url: '/api/v1/widget/contact', headers: { 'X-Auth-Token': 'tbwp1.expired' }, data: body }) });
await Promise.all([rejectResponse(expired()), rejectResponse(expired())]);
assert.equal(refreshes.length, 1, 'Concurrent expiry responses share one proof renewal');
assert.equal(retries.length, 2);
assert.ok(retries.every(config => config.headers['X-Auth-Token'] === 'tbwp1.renewed' && config.data === body));
assert.equal(actualClient.defaults.headers.common['X-Toybaco-Widget'], '1');
assert.deepEqual(proofEvents, ['toybaco-widget-proof-updated']);
const unrelated = { response: { status: 404, data: { error: 'not_found' } }, config: { headers: {} } };
await assert.rejects(rejectResponse(unrelated), error => error === unrelated);
assert.equal(refreshes.length, 1, 'A business failure is never retried as an authentication failure');
const beforeSwitch = expired();
axiosContext.window.toybacoWidgetIdentityGeneration = 1;
axiosContext.window.authToken = 'tbwp1.other-identity';
await assert.rejects(rejectResponse(beforeSwitch), error => error === beforeSwitch);
assert.equal(refreshes.length, 1, 'A late old-identity 401 never starts renewal with the new identity');
assert.equal(retries.length, 2, 'The old request body is never replayed as the new visitor');
axiosContext.window.toybacoWidgetIdentityGeneration = 2;
axiosContext.window.authToken = 'tbwp1.expired';
const duringSwitch = expired();
let releaseProof;
actualClient.post = async (...args) => { refreshes.push(args); return new Promise(resolve => { releaseProof = resolve; }); };
const blockedRetry = rejectResponse(duringSwitch);
assert.equal(refreshes.at(-1)[2].headers['X-Auth-Token'], 'tbwp1.expired', 'Renewal is bound to the original request proof');
axiosContext.window.toybacoWidgetIdentityGeneration = 3;
axiosContext.window.authToken = 'tbwp1.new-identity';
releaseProof({ data: { proof: 'tbwp1.old-identity-refreshed' } });
await assert.rejects(blockedRetry, error => error === duringSwitch);
assert.equal(retries.length, 2, 'Identity change while renewal is pending also prevents a retry');
assert.equal(axiosContext.window.authToken, 'tbwp1.new-identity');
console.log('Widget HTTP session actual Axios renewal: one shared refresh, exact auth-expiry marker, unchanged body, fresh proof and no business retry PASS');

const operationSource = read('overlay/app/app/javascript/widget/helpers/identityOperations.js').replaceAll('export const ', 'const ');
const operationContext = { window: axiosContext.window };
vm.runInNewContext(`${operationSource}\nthis.run = runIdentityOperation; this.reset = runIdentityReset;`, operationContext);
const fenceSource = read('overlay/app/app/javascript/widget/helpers/identityStoreFence.js')
  .replace(/^import [^\n]+\n/gm, '').replaceAll('export const ', 'const ');
const fenceContext = { window: axiosContext.window, runIdentityOperation: operationContext.run };
vm.runInNewContext(`${fenceSource}\nthis.guard = guardWidgetModules;`, fenceContext);
const contactsSource = read('overlay/app/app/javascript/widget/store/modules/contacts.js')
  .replace(/^import [^\n]+\n/gm, '').replaceAll('export const ', 'const ')
  .replace(/export default \{[\s\S]*$/, '');
let releaseFirstUser;
const contactDispatches = []; const identityCalls = [];
axiosContext.window.toybacoHttpSession = true;
axiosContext.transportSetHeader('tbwp1.expired');
axiosContext.window.location = { search: '?website_token=public', href: 'https://app.example.test/widget?website_token=public' };
actualClient.patch = async (url, data, options) => {
  const config = prepareRequest({ url, data, method: 'patch', headers: { ...actualClient.defaults.headers.common }, ...options });
  identityCalls.push({ identifier: data.identifier, proof: config.headers['X-Auth-Token'] });
  const result = data.identifier === 'A'
    ? await new Promise(resolve => { releaseFirstUser = resolve; })
    : { widget_auth_token: 'tbwp1.B', widget_http_identity_changed: true };
  return acceptResponse({ data: result, config });
};
const contactsApiSource = read('overlay/app/app/javascript/widget/api/contacts.js')
  .replace(/^import [^\n]+\n/gm, '').replace('export default {', 'this.ContactsAPI = {');
const contactsApiContext = { API: actualClient, window: axiosContext.window };
vm.runInNewContext(contactsApiSource, contactsApiContext);
const contactsContext = { window: axiosContext.window, sendMessage: () => {}, SET_USER_ERROR: 'synthetic',
  setHeader: axiosContext.transportSetHeader, ContactsAPI: contactsApiContext.ContactsAPI };
vm.runInNewContext(`${contactsSource}\nthis.contactActions = actions;`, contactsContext);
const guarded = fenceContext.guard({ contacts: { actions: contactsContext.contactActions } });
const contactContext = { commit: () => {}, dispatch: (...args) => contactDispatches.push(args) };
const firstUser = guarded.contacts.actions.setUser(contactContext, { identifier: 'A', user: {} });
await Promise.resolve(); await Promise.resolve();
assert.equal(identityCalls.length, 1);
const oldSetUserError = expired();
const oldSuccessful = { data: { synthetic: 'old-history' }, config: oldSetUserError.config };
const secondUser = guarded.contacts.actions.setUser(contactContext, { identifier: 'B', user: {} });
assert.equal(identityCalls.length, 1, 'A second setUser cannot race the first request using its old proof');
const retryCountBeforeLateSetUser = retries.length;
axiosContext.window.toybacoWidgetIdentityGeneration += 1;
assert.throws(() => acceptResponse(oldSuccessful), /TOYBACO_WIDGET_STALE_RESPONSE/);
await assert.rejects(rejectResponse(oldSetUserError), error => error === oldSetUserError);
releaseFirstUser({ widget_auth_token: 'tbwp1.A-confirmed', widget_http_identity_changed: true });
await Promise.all([firstUser, secondUser]);
assert.equal(identityCalls[1].proof, 'tbwp1.A-confirmed', 'The queued identity request starts only with the confirmed first proof');
assert.equal(axiosContext.window.authToken, 'tbwp1.B');
assert.equal(retries.length, retryCountBeforeLateSetUser, 'The old request body cannot be retried after identification starts');
let deliverContact; const commits = [];
contactsContext.ContactsAPI.get = async () => new Promise(resolve => { deliverContact = resolve; });
const pendingContact = guarded.contacts.actions.get({ commit: (...args) => commits.push(args), dispatch: () => {} });
axiosContext.window.toybacoWidgetIdentityGeneration += 1;
deliverContact({ data: { synthetic: 'old-contact' } });
await pendingContact;
assert.equal(commits.length, 0, 'Actual contacts.get cannot commit when Axios resolution crosses an identity change');
assert.ok(read('overlay/app/app/javascript/widget/store/index.js').includes('modules: guardWidgetModules({'));
const cableSource = read('overlay/app/app/javascript/widget/helpers/actionCable.js')
  .replace(/^import [^\n]+\n/gm, '').replace('export default ActionCableConnector;', 'this.Cable = ActionCableConnector;');
const mergeDispatches = [];
const cableContext = { window: axiosContext.window, Event: axiosContext.Event,
  BaseActionCableConnector: class { constructor(app) { this.app = app; } }, setTimeout: () => 0, clearTimeout: () => {} };
vm.runInNewContext(cableSource, cableContext);
const cable = new cableContext.Cable({ $store: { dispatch: (...args) => mergeDispatches.push(args), getters: {} } }, 'public-stream');
const beforeMergeRequest = expired();
cable.events['toybaco.widget.identity-changed']({});
await assert.rejects(rejectResponse(beforeMergeRequest), error => error === beforeMergeRequest);
assert.throws(() => acceptResponse({ data: {}, config: beforeMergeRequest.config }), /TOYBACO_WIDGET_STALE_RESPONSE/);
assert.equal(retries.length, retryCountBeforeLateSetUser);
assert.ok(mergeDispatches.some(([action]) => action === 'contacts/get'));
// Run the actual fixed upstream conversation action, not a hand-written lookalike.
let finishCreate; const createCommits = []; const createdEvents = [];
const conversationSource = readActual('app/javascript/widget/store/modules/conversation/actions.js')
  .replace(/^import\s[\s\S]*?;\n/gm, '').replace('export const actions =', 'const actions =');
const conversationContext = { ON_CONVERSATION_CREATED: 'created', emitter: { emit: event => createdEvents.push(event) },
  createConversationAPI: async () => {
    const config = prepareRequest({ url: '/api/v1/widget/conversations', method: 'post', headers: { ...actualClient.defaults.headers.common } });
    await new Promise(resolve => { finishCreate = resolve; });
    return acceptResponse({ data: { messages: [{ id: 'synthetic-created' }] }, config });
  } };
vm.runInNewContext(`${conversationSource}\nthis.actions = actions;`, conversationContext);
const conversationModule = fenceContext.guard({ conversation: { actions: conversationContext.actions } });
const createPending = conversationModule.conversation.actions.createConversation(
  { commit: (...args) => createCommits.push(args), dispatch: () => Promise.resolve() }, {});
await Promise.resolve(); await Promise.resolve();
cable.events['toybaco.widget.identity-changed']({});
finishCreate(); await createPending;
assert.equal(createdEvents.length, 1, 'A committed merge notice cannot swallow actual conversation creation success');
assert.ok(createCommits.some(([name, value]) => name === 'pushMessageToConversation' && value.id === 'synthetic-created'));
assert.equal(createCommits.at(-1)[1].isCreating, false, 'The actual upstream finally clears its waiting state after merge-before-200');
// Exercise the actual history action after its API promise resolves but before
// its async continuation: there must be no direct live-state write around commit.
let finishHistory; const historyCommits = [];
conversationContext.getMessagesAPI = () => new Promise(resolve => { finishHistory = resolve; });
conversationContext.getNonDeletedMessages = ({ messages }) => messages;
const mutationSource = readActual('app/javascript/widget/store/modules/conversation/mutations.js')
  .replace(/^import [^\n]+\n/gm, '').replace('export const mutations =', 'const mutations =');
const mutationContext = { MESSAGE_TYPE: { INCOMING: 0 }, findUndeliveredMessage: () => [] };
vm.runInNewContext(`${mutationSource}\nthis.mutations = mutations;`, mutationContext);
const historyState = { lastMessageId: 1, meta: {}, uiFlags: { isFetchingList: false },
  conversations: { current: { id: 'current', created_at: 1 } } };
const commitHistory = (name, value) => {
  historyCommits.push([name, value]);
  mutationContext.mutations[name.replace('conversation/', '')](historyState, value);
};
const historyPending = conversationModule.conversation.actions.syncLatestMessages({ state: historyState,
  commit: commitHistory, dispatch: () => Promise.resolve() });
finishHistory({ data: { payload: [{ id: 'old-visitor', created_at: 2 }], meta: { contact_last_seen_at: 3 } } });
axiosContext.window.toybacoWidgetIdentityGeneration += 1;
await historyPending;
assert.equal(Object.keys(historyState.conversations).length, 1, 'Actual history action cannot mutate live state around a rejected commit');
assert.equal(historyCommits.length, 0, 'Resolved old-identity data cannot reach the guarded commit');
const currentHistory = conversationModule.conversation.actions.syncLatestMessages({ state: historyState,
  commit: commitHistory, dispatch: () => Promise.resolve() });
finishHistory({ data: { payload: [{ id: 'same-visitor', created_at: 2 }], meta: { contact_last_seen_at: 3 } } });
await currentHistory;
assert.equal(Object.keys(historyState.conversations).length, 2, 'The actual normal mutation installs the candidate into the live conversations collection');
assert.equal(historyState.conversations['same-visitor'].id, 'same-visitor');
assert.equal(historyState.meta.userLastSeenAt, 3);
assert.equal(Object.hasOwn(historyState, 'conversation'), false, 'No obsolete singular collection is created');
assert.ok(historyCommits.some(([name, value]) => name === 'setMissingMessagesInConversation' && value['same-visitor']));
// Actual shared interceptor code + history action + actual mutations, using
// an instrumented transport/plain state (real adapter/store acceptance is live).
// Attribute-only operations
// serialize proof use without invalidating same-visitor history. When identity
// really changes, only the request owning the loading flag may release it.
const historyRequests = [];
conversationContext.getMessagesAPI = async params => {
  const config = prepareRequest({ url: '/api/v1/widget/messages', method: 'get', params,
    headers: { ...actualClient.defaults.headers.common } });
  const data = await new Promise(resolve => { historyRequests.push(resolve); });
  return acceptResponse({ config, data });
};
const historyActionContext = { state: historyState, commit: commitHistory, dispatch: () => Promise.resolve() };
const historyReply = id => ({ payload: [{ id, created_at: 5 }], meta: { contact_last_seen_at: 4 } });
const attributeHistory = conversationModule.conversation.actions.fetchOldConversations(historyActionContext);
assert.equal(historyState.uiFlags.isFetchingList, true);
const generationBeforeAttribute = axiosContext.window.toybacoWidgetIdentityGeneration;
await guarded.contacts.actions.setCustomAttributes(contactContext, { synthetic: true });
assert.equal(axiosContext.window.toybacoWidgetIdentityGeneration, generationBeforeAttribute,
  'Attribute-only callers do not pretend that the visitor identity changed');
historyRequests.shift()(historyReply('same-visitor-attribute-history'));
await attributeHistory;
assert.equal(historyState.uiFlags.isFetchingList, false);
assert.ok(historyState.conversations['same-visitor-attribute-history']);
const cancelledHistory = conversationModule.conversation.actions.fetchOldConversations(historyActionContext);
cable.events['toybaco.widget.identity-changed']({});
historyRequests.shift()(historyReply('cancelled-history'));
await cancelledHistory;
assert.equal(historyState.uiFlags.isFetchingList, false, 'A stale request releases only its own pending loading state');
assert.equal(historyState.conversations['cancelled-history'], undefined);
const oldHistoryLoading = conversationModule.conversation.actions.fetchOldConversations(historyActionContext);
cable.events['toybaco.widget.identity-changed']({});
const newHistoryLoading = conversationModule.conversation.actions.fetchOldConversations(historyActionContext);
historyRequests.shift()(historyReply('old-history-loading'));
await oldHistoryLoading;
assert.equal(historyState.uiFlags.isFetchingList, true, 'Old cleanup cannot clear a newer request loading flag');
historyRequests.shift()(historyReply('current-history-loading'));
await newHistoryLoading;
assert.equal(historyState.uiFlags.isFetchingList, false);
assert.equal(historyState.conversations['old-history-loading'], undefined);
assert.ok(historyState.conversations['current-history-loading']);
// Reverse two real reconnect action responses around actual socket delivery.
// The late response may add missing records, never replace current state or a
// newer version delivered by the websocket action.
const raceState = { lastMessageId: 1, meta: {}, uiFlags: {}, conversations: { 1: { id: 1, created_at: 1 } } };
const raceContext = { state: raceState, dispatch: () => Promise.resolve(), commit: (name, value) => {
  mutationContext.mutations[name.replace('conversation/', '')](raceState, value);
} };
const slowReconnect = conversationModule.conversation.actions.syncLatestMessages(raceContext);
const fastReconnect = conversationModule.conversation.actions.syncLatestMessages(raceContext);
const releaseSlowReconnect = historyRequests.shift();
const releaseFastReconnect = historyRequests.shift();
releaseFastReconnect({ payload: [{ id: 3, created_at: 3, content: 'fast' }], meta: { contact_last_seen_at: 5 } });
await fastReconnect;
await conversationModule.conversation.actions.addOrUpdateMessage(raceContext,
  { id: 4, created_at: 4, message_type: 1, content: 'socket-new' });
await conversationModule.conversation.actions.addOrUpdateMessage(raceContext,
  { id: 3, created_at: 3, message_type: 1, content: 'socket-updated' });
releaseSlowReconnect({ payload: [{ id: 2, created_at: 2 }, { id: 3, created_at: 3, content: 'stale-copy' }],
  meta: { contact_last_seen_at: 4 } });
await slowReconnect;
assert.deepEqual(Object.keys(raceState.conversations), ['1', '2', '3', '4']);
assert.equal(raceState.conversations[3].content, 'socket-updated', 'A late reconnect cannot roll back newer socket content');
assert.equal(raceState.conversations[4].content, 'socket-new', 'A late reconnect cannot remove an intervening message');
console.log('Widget actual history ownership/reconnect: attribute history completion, stale cleanup ownership, reverse response order and intervening socket state PASS');
// Execute the fixed upstream MessageAPI/action/mutation for actual option,
// form and CSAT answers. Only an email-bearing update can identify a contact.
const messageApiSource = readActual('app/javascript/widget/api/message.js')
  .replace(/^import [^\n]+\n/gm, '').replace('export default {', 'this.MessageAPI = {');
const messageApiContext = { API: actualClient,
  authEndPoint: { updateMessage: id => ({ url: `/api/v1/widget/messages/${id}?website_token=public` }) } };
vm.runInNewContext(messageApiSource, messageApiContext);
const messageSource = readActual('app/javascript/widget/store/modules/message.js')
  .replace(/^import [^\n]+\n/gm, '').replaceAll('export const ', 'const ').replace(/export default \{[\s\S]*$/, '');
const messageContext = { MessageAPI: messageApiContext.MessageAPI };
vm.runInNewContext(`${messageSource}\nthis.actions = actions; this.mutations = mutations;`, messageContext);
const messageModule = fenceContext.guard({ message: { actions: messageContext.actions } });
const messageState = { uiFlags: { isUpdating: false } };
const messageActionContext = { state: messageState, getters: { getUIFlags: messageState.uiFlags }, dispatch: () => Promise.resolve(),
  commit: (name, value) => {
    if (name.startsWith('conversation/')) commitHistory(name, value);
    else messageContext.mutations[name](messageState, value);
  } };
for (const [index, contentType] of ['input_select', 'form', 'input_csat'].entries()) {
  const messageId = 501 + index; const arrivingId = 601 + index;
  historyState.conversations[messageId] = { id: messageId, content_type: contentType, created_at: 6, content_attributes: {} };
  const reconnect = conversationModule.conversation.actions.syncLatestMessages(historyActionContext);
  const generationBeforeAnswer = axiosContext.window.toybacoWidgetIdentityGeneration;
  await messageModule.message.actions.update(messageActionContext,
    { messageId, submittedValues: [{ name: 'synthetic', value: contentType }] });
  assert.equal(axiosContext.window.toybacoWidgetIdentityGeneration, generationBeforeAnswer,
    'A non-email answer must not discard a pending reconnect');
  historyRequests.shift()({ payload: [{ id: arrivingId, created_at: 7 }], meta: { contact_last_seen_at: 6 } });
  await reconnect;
  assert.ok(historyState.conversations[arrivingId], 'Reconnect message remains visible after the actual answer action');
  assert.equal(historyState.conversations[messageId].content_attributes.submitted_values[0].value, contentType);
  assert.equal(messageState.uiFlags.isUpdating, false);
}
const metadataRead = conversationModule.conversation.actions.syncLatestMessages(historyActionContext);
const generationBeforeMetadata = axiosContext.window.toybacoWidgetIdentityGeneration;
await guarded.contacts.actions.update(contactContext, { user: { name: 'Synthetic name', custom_attributes: { synthetic: true } } });
assert.equal(axiosContext.window.toybacoWidgetIdentityGeneration, generationBeforeMetadata);
historyRequests.shift()({ payload: [{ id: 604, created_at: 8 }], meta: { contact_last_seen_at: 6 } });
await metadataRead;
assert.ok(historyState.conversations[604], 'A metadata-only contact update preserves a pending history read');
historyState.conversations[505] = { id: 505, content_type: 'input_email', created_at: 9, content_attributes: {} };
const generationBeforeEmail = axiosContext.window.toybacoWidgetIdentityGeneration;
await messageModule.message.actions.update(messageActionContext, { messageId: 505, email: 'synthetic@example.test' });
assert.equal(axiosContext.window.toybacoWidgetIdentityGeneration, generationBeforeEmail + 1,
  'Actual email-identification updates keep their identity fence');
console.log('Widget actual nonidentifying updates: option/form/CSAT and metadata reads preserved, email identification fence retained PASS');
// Public agent state must finish even if identification changes during its GET.
let finishAgents; const agentCommits = [];
const agentSource = readActual('app/javascript/widget/store/modules/agent.js')
  .replace(/^import [^\n]+\n/gm, '').replaceAll('export const ', 'const ').replace(/export default \{[\s\S]*$/, '');
const agentsContext = { MutationHelpers: { updatePresence() {} }, getFromCache: () => undefined, setCache() {},
  getAvailableAgents: async () => {
    const config = prepareRequest({ url: '/api/v1/widget/inbox_members', method: 'get', headers: {} });
    await new Promise(resolve => { finishAgents = resolve; });
    return acceptResponse({ config, data: { payload: [{ id: 'public-agent' }] } });
  } };
vm.runInNewContext(`${agentSource}\nthis.actions = actions;`, agentsContext);
const publicModules = fenceContext.guard({ agent: { actions: agentsContext.actions } });
const publicPending = publicModules.agent.actions.fetchAvailableAgents({ commit: (...args) => agentCommits.push(args) }, 'public');
axiosContext.window.toybacoWidgetIdentityGeneration += 1;
finishAgents(); await publicPending;
assert.ok(agentCommits.some(([name, value]) => name === 'setAgents' && value[0].id === 'public-agent'));
assert.ok(agentCommits.some(([name, value]) => name === 'setHasFetched' && value === true));
// Execute actual reset during a pending setUser; DELETE must use its confirmed proof.
let resetListener; const acknowledgements = []; const deletes = [];
const parentForReset = { postMessage: data => acknowledgements.push(JSON.parse(data.slice('chatwoot-widget:'.length))) };
axiosContext.window.parent = parentForReset;
axiosContext.window.toybacoWidgetParentOrigin = 'https://shop.example.test';
axiosContext.window.addEventListener = (_event, listener) => { resetListener = listener; };
actualClient.delete = async (url, options) => {
  const config = prepareRequest({ url, method: 'delete', headers: { ...actualClient.defaults.headers.common }, ...options });
  deletes.push(config.headers['X-Auth-Token']);
  return acceptResponse({ config, data: { session_revoked: true } });
};
const actualResetSource = read('overlay/app/app/javascript/widget/helpers/sessionReset.js')
  .replace(/^import [^\n]+\n/gm, '').replace('export const installSessionReset', 'const installSessionReset');
vm.runInNewContext(`${actualResetSource}\ninstallSessionReset();`, { window: axiosContext.window, URL, API: actualClient,
  runIdentityReset: operationContext.reset });
const userBeforeReset = guarded.contacts.actions.setUser(contactContext, { identifier: 'A', user: {} });
await Promise.resolve(); await Promise.resolve();
const callsBeforeReset = identityCalls.length;
const queuedBeforeReset = guarded.contacts.actions.setUser(contactContext, { identifier: 'cancelled', user: {} });
const resetPending = resetListener({ source: parentForReset, origin: 'https://shop.example.test',
  data: `chatwoot-widget:${JSON.stringify({ event: 'revoke-session', requestId: 'a'.repeat(32) })}` });
assert.equal(deletes.length, 0, 'Reset waits for an executing identity response rather than invalidating its proof');
releaseFirstUser({ widget_auth_token: 'tbwp1.confirmed-before-reset', widget_http_identity_changed: true });
await Promise.all([userBeforeReset, queuedBeforeReset, resetPending]);
assert.equal(deletes[0], 'tbwp1.confirmed-before-reset');
assert.equal(deletes.length, 1);
assert.equal(identityCalls.length, callsBeforeReset, 'Reset cancels identity requests that have not started');
assert.equal(acknowledgements.at(-1).success, true);
console.log('Widget actual operation/store/reset/merge callers: confirmed proof chaining, stale 200/401 refusal, public agent completion and merge-before-200 UI completion PASS');

const popoutSource = read('overlay/app/app/javascript/widget/helpers/httpPopout.js')
  .replace(/^import [^\n]+\n/gm, '').replaceAll('export const ', 'const ');
const popup = { closed: false, focus: () => {}, messages: [], postMessage(data, origin) { this.messages.push({ data: JSON.parse(data.slice('chatwoot-widget:'.length)), origin }); } };
const popupListeners = new Set(); const opened = []; const grants = [];
const popupContext = { URL, setTimeout: () => {}, sessionRequest: async () => { throw new Error('Parent must delegate to actual iframe'); },
  window: { open: (...args) => { opened.push(args); return popup; },
    addEventListener: (_type, fn) => popupListeners.add(fn), removeEventListener: (_type, fn) => popupListeners.delete(fn) } };
vm.runInNewContext(`${popoutSource}\nthis.open = openHttpPopout;`, popupContext);
popupContext.open('https://app.example.test', 'public', 'ja', async id => { grants.push(id); return { code: 'd'.repeat(64) }; });
const popupURL = new URL(opened[0][0]);
assert.equal(popupURL.searchParams.get('toybaco_popout'), '2');
assert.equal(popupURL.searchParams.has('cw_conversation'), false);
const popupChallenge = { source: popup, origin: 'https://app.example.test',
  data: `chatwoot-widget:${JSON.stringify({ event: 'http-session-inert', popout: true, requestId: 'a'.repeat(64) })}` };
for (const override of [{ source: {} }, { origin: 'https://foreign.example.test' }]) {
  for (const listener of popupListeners) await listener({ ...popupChallenge, ...override });
}
assert.equal(grants.length, 0);
for (let index = 0; index < 2; index++) for (const listener of popupListeners) await listener(popupChallenge);
assert.equal(grants.length, 1, 'Duplicate popup challenges cannot create two grants');
assert.ok(popup.messages.every(item => item.origin === 'https://app.example.test' && item.data.handoffCode === 'd'.repeat(64)));
console.log('Widget HTTP popout actual transport: public URL only, exact opened window/origin/challenge, single grant and body handoff PASS');

const renewalEvents = {}; const renewalDocumentEvents = {}; const renewalIntervals = []; const renewalUpdates = [];
let resolveRenewal;
const renewalWindow = { authToken: 'tbwp1.old', toybacoHttpSession: true,
  location: { origin: 'https://app.example.test' }, chatwootWebChannel: { websiteToken: 'public' },
  addEventListener: (type, listener) => { renewalEvents[type] = listener; } };
const renewalContext = { window: renewalWindow, URL,
  document: { hidden: false, addEventListener: (type, listener) => { renewalDocumentEvents[type] = listener; } },
  fetch: () => new Promise(resolve => { resolveRenewal = resolve; }),
  setInterval: (fn, duration) => renewalIntervals.push({ fn, duration }) };
vm.runInNewContext(`${source}\nthis.installRenewal = installHttpProofRenewal;`, renewalContext);
renewalContext.installRenewal(proof => { renewalUpdates.push(proof); renewalWindow.authToken = proof; });
assert.equal(renewalIntervals[0].duration, 12 * 60 * 60 * 1000);
assert.equal(typeof renewalDocumentEvents.visibilitychange, 'function');
const renewal = renewalEvents.online();
renewalWindow.authToken = 'tbwp1.new-identity';
resolveRenewal({ ok: true, json: async () => ({ proof: 'tbwp1.stale-response' }) });
await renewal;
assert.equal(renewalUpdates.length, 0, 'A delayed renewal cannot roll back a newer identity');
const currentRenewal = renewalIntervals[0].fn();
resolveRenewal({ ok: true, json: async () => ({ proof: 'tbwp1.fresh' }) });
await currentRenewal;
assert.deepEqual(renewalUpdates, ['tbwp1.fresh']);
const revokedRenewal = renewalEvents.online();
resolveRenewal({ ok: false, json: async () => ({ error: 'Widget session unavailable' }) });
await revokedRenewal;
assert.deepEqual(renewalUpdates, ['tbwp1.fresh'], 'Revocation never starts a replacement anonymous session');
console.log('Widget idle renewal actual implementation: 12h timer, visibility/online resume, re-subscription callback, late-identity fence and revoked failure PASS');
