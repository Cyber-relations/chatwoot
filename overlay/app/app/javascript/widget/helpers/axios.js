import axios from 'axios';
import { stripWidgetSessionQuery } from './urlParamsHelper';
import { APP_BASE_URL } from 'widget/helpers/constants';

const identityGeneration = () => window.toybacoWidgetIdentityGeneration || 0;
const requestPath = config => (config.url || '').split('?')[0];
const privateIdentityRequest = config => requestPath(config).startsWith('/api/v1/widget/') &&
  requestPath(config) !== '/api/v1/widget/inbox_members';
const identityOperationRequest = config => {
  const path = requestPath(config);
  const method = (config.method || 'get').toLowerCase();
  return (path === '/api/v1/widget/contact/set_user' && method === 'patch') ||
    (path === '/api/v1/widget/contact' && method === 'patch') ||
    (path === '/api/v1/widget/contact/destroy_custom_attributes' && method === 'post') ||
    (path === '/api/v1/widget/conversations' && method === 'post') ||
    (/^\/api\/v1\/widget\/messages\/[^/]+$/.test(path) && method === 'patch') ||
    (path === '/api/v1/widget/session' && method === 'delete');
};

export const API = axios.create({
  baseURL: APP_BASE_URL,
  withCredentials: false,
});

// Some upstream callers copy location.search directly instead of using the
// endpoint builder. Enforce the transport boundary on the actual Axios client.
API.interceptors.request.use(config => {
  if (window.toybacoHttpSession && identityOperationRequest(config)) {
    const operation = window.toybacoWidgetActiveOperation;
    if (typeof operation !== 'number') throw new Error('TOYBACO_WIDGET_IDENTITY_QUEUE_REQUIRED');
    config.toybacoIdentityTransition = true;
    config.toybacoOperationGeneration = operation;
  }
  config.toybacoIdentityGeneration ??= identityGeneration();
  config.toybacoRequestProof ??= config.headers?.['X-Auth-Token'] || config.headers?.['x-auth-token'] ||
    API.defaults.headers.common['X-Auth-Token'];
  config.url = stripWidgetSessionQuery(config.url);
  if (config.params instanceof URLSearchParams) {
    config.params = new URLSearchParams(config.params);
    config.params.delete('cw_conversation');
  } else if (config.params && Object.getPrototypeOf(config.params) === Object.prototype) {
    config.params = { ...config.params };
    delete config.params.cw_conversation;
  }
  return config;
});

let proofRefresh;
const refreshRequestProof = (requestedProof, generation) => {
  if (proofRefresh?.generation === generation && proofRefresh?.proof === requestedProof) return proofRefresh.promise;
  const refresh = { generation, proof: requestedProof };
  refresh.promise = API.post('/api/v1/widget/http_session/proof', {}, {
    params: { website_token: window.chatwootWebChannel.websiteToken },
    headers: { 'X-Auth-Token': requestedProof }, toybacoProofRefresh: true,
  }).then(response => {
    if (!response.data?.proof?.startsWith('tbwp1.')) throw new Error('Widget proof renewal failed');
    return response.data.proof;
  }).finally(() => { if (proofRefresh === refresh) proofRefresh = undefined; });
  proofRefresh = refresh;
  return refresh.promise;
};
const currentIdentityResponse = config => config.toybacoIdentityTransition === true &&
  typeof config.toybacoOperationGeneration === 'number' && identityOperationRequest(config) &&
  config.toybacoOperationGeneration === window.toybacoWidgetOperationGeneration &&
  config.toybacoOperationGeneration === window.toybacoWidgetActiveOperation;

API.interceptors.response.use(response => {
  const config = response.config;
  if (window.toybacoHttpSession && config && privateIdentityRequest(config) && config.toybacoIdentityGeneration !== identityGeneration() &&
    !currentIdentityResponse(config)) {
    throw new Error('TOYBACO_WIDGET_STALE_RESPONSE');
  }
  return response;
}, async error => {
  const config = error.config;
  if (error.response?.status !== 401 || error.response?.data?.error !== 'widget_proof_expired' ||
    !config || config.toybacoRetried || config.toybacoProofRefresh ||
    config.toybacoIdentityGeneration !== identityGeneration()) throw error;
  config.toybacoRetried = true;
  const requestedProof = config.toybacoRequestProof;
  if (!requestedProof?.startsWith('tbwp1.')) throw error;
  const generation = config.toybacoIdentityGeneration;
  if (window.authToken === requestedProof) {
    const fresh = await refreshRequestProof(requestedProof, generation);
    if (generation !== identityGeneration()) throw error;
    if (window.authToken === requestedProof) setHeader(fresh);
  }
  if (generation !== identityGeneration()) throw error;
  const proof = window.authToken;
  if (!proof?.startsWith('tbwp1.')) throw error;
  config.headers['X-Auth-Token'] = proof;
  return API.request(config);
});

export const setHeader = (value, key = 'X-Auth-Token') => {
  API.defaults.headers.common[key] = value;
  if (key === 'X-Auth-Token' && /^tbw[pr]1\./.test(value || '')) {
    API.defaults.headers.common['X-Toybaco-Widget'] = '1';
    const changed = window.authToken !== value;
    window.authToken = value;
    if (changed) window.dispatchEvent(new Event('toybaco-widget-proof-updated'));
  }
};

export const removeHeader = key => {
  delete API.defaults.headers.common[key];
};
