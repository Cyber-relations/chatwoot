import { browserSessionHeaders } from './browserSession';

export const setDirectUploadAuthHeaders = (xhr) => {
  const headers = browserSessionHeaders();
  if (!headers['X-CSRF-Token']) throw new Error('CSRF token is missing');
  Object.entries(headers).forEach(([name, value]) =>
    xhr.setRequestHeader(name, value)
  );
};
