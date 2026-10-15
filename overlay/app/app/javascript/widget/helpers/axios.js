import axios from 'axios';
import { stripWidgetSessionQuery } from './urlParamsHelper';
import { APP_BASE_URL } from 'widget/helpers/constants';

export const API = axios.create({
  baseURL: APP_BASE_URL,
  withCredentials: false,
});

// Some upstream callers copy location.search directly instead of using the
// endpoint builder. Enforce the transport boundary on the actual Axios client.
API.interceptors.request.use(config => {
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

export const setHeader = (value, key = 'X-Auth-Token') => {
  API.defaults.headers.common[key] = value;
};

export const removeHeader = key => {
  delete API.defaults.headers.common[key];
};
