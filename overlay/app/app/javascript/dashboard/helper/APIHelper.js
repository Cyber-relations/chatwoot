import { configureBrowserSession } from './browserSession';

export default (axios) => {
  const { apiHost = '' } = window.chatwootConfig || {};
  return configureBrowserSession(axios.create({ baseURL: `${apiHost}/` }));
};
