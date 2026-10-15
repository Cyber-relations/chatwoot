// Remove only the known private query key; leave URLs without it byte-for-byte.
export const stripWidgetSessionQuery = url => {
  if (typeof url !== 'string') return url;
  const queryStart = url.indexOf('?');
  const fragmentStart = url.indexOf('#');
  if (queryStart < 0 || (fragmentStart >= 0 && fragmentStart < queryStart)) return url;
  const end = fragmentStart >= 0 ? fragmentStart : url.length;
  const params = new URLSearchParams(url.slice(queryStart + 1, end));
  if (!params.has('cw_conversation')) return url;
  params.delete('cw_conversation');
  const query = params.toString();
  return url.slice(0, queryStart) + (query ? `?${query}` : '') + url.slice(end);
};

export const buildSearchParamsWithLocale = search => {
  // [TODO] for now this works, but we will need to find a way to get the locale from the root component
  const locale = window.WOOT_WIDGET.$root.$i18n.locale;
  const params = new URLSearchParams(search);
  // API authentication already uses the header; never copy the bootstrap
  // visitor token into every API URL (including duplicate/encoded keys).
  params.delete('cw_conversation');
  params.append('locale', locale);

  return `?${params}`;
};

export const getLocale = (search = '') => {
  return new URLSearchParams(search).get('locale');
};

export const buildPopoutURL = ({
  origin,
  conversationCookie,
  websiteToken,
  locale,
}) => {
  const popoutUrl = new URL('/widget', origin);
  popoutUrl.searchParams.append('cw_conversation', conversationCookie);
  popoutUrl.searchParams.append('website_token', websiteToken);
  popoutUrl.searchParams.append('locale', locale);

  return popoutUrl.toString();
};
