import axios from 'axios';
import { configureBrowserSession } from 'dashboard/helper/browserSession';

const { apiHost = '' } = window.chatwootConfig || {};
export default configureBrowserSession(
  axios.create({ baseURL: `${apiHost}/` })
);
