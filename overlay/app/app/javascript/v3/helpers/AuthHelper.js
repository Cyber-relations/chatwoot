import Cookies from 'js-cookie';
import { DEFAULT_REDIRECT_URL } from 'dashboard/constants/globals';
import { frontendURL } from 'dashboard/helper/URLHelper';

export const hasAuthCookie = () => {
  return !!Cookies.get('cw_d_session_info');
};

const NOTIFICATION_ACCOUNT_KEY = 'toybaco_return_account_id';
const NOTIFICATION_CONVERSATION_KEY = 'toybaco_return_conversation_id';
const isCanonicalId = value =>
  typeof value === 'string' &&
  /^[1-9]\d*$/.test(value) &&
  Number.isSafeInteger(Number(value)) &&
  String(Number(value)) === value;

export const getNotificationLoginURL = path => {
  const match =
    typeof path === 'string' &&
    path.match(/^\/app\/accounts\/([1-9]\d*)\/conversations\/([1-9]\d*)$/);
  if (
    !match ||
    match[0] !== path ||
    !isCanonicalId(match[1]) ||
    !isCanonicalId(match[2])
  ) {
    return frontendURL('login');
  }
  const query = new URLSearchParams({
    [NOTIFICATION_ACCOUNT_KEY]: match[1],
    [NOTIFICATION_CONVERSATION_KEY]: match[2],
  });
  return frontendURL(`login?${query}`);
};

export const getNotificationConversationURL = user => {
  if (window.location.pathname !== frontendURL('login')) return '';
  const query = new URLSearchParams(window.location.search);
  if (
    ['sso_auth_token', 'sso_account_id', 'sso_conversation_id'].some(key =>
      query.has(key)
    )
  ) {
    return '';
  }
  const accountIds = query.getAll(NOTIFICATION_ACCOUNT_KEY);
  const conversationIds = query.getAll(NOTIFICATION_CONVERSATION_KEY);
  if (
    accountIds.length !== 1 ||
    conversationIds.length !== 1 ||
    !isCanonicalId(accountIds[0]) ||
    !isCanonicalId(conversationIds[0])
  ) {
    return '';
  }
  const account = user?.accounts?.find(
    membership => membership.id === Number(accountIds[0])
  );
  if (!account) return '';
  return frontendURL(
    `accounts/${accountIds[0]}/conversations/${conversationIds[0]}`
  );
};

const getSSOAccountPath = ({ ssoAccountId, user }) => {
  const { accounts = [], account_id = null } = user || {};
  const ssoAccount = accounts.find(
    account => account.id === Number(ssoAccountId)
  );
  let accountPath = '';
  if (ssoAccount) {
    accountPath = `accounts/${ssoAccountId}`;
  } else if (accounts.length) {
    // If the account id is not found, redirect to the first account
    const accountId = account_id || accounts[0].id;
    accountPath = `accounts/${accountId}`;
  }
  return accountPath;
};

const capitalize = str =>
  str
    .split(/[._-]+/)
    .map(word => word.charAt(0).toUpperCase() + word.slice(1))
    .join(' ');

export const getCredentialsFromEmail = email => {
  const [localPart, domain] = email.split('@');
  const namePart = localPart.split('+')[0];
  return {
    fullName: capitalize(namePart),
    accountName: capitalize(domain.split('.')[0]),
  };
};

export const getLoginRedirectURL = ({
  ssoAccountId,
  ssoConversationId,
  user,
}) => {
  if (!ssoAccountId && !ssoConversationId) {
    const notificationURL = getNotificationConversationURL(user);
    if (notificationURL) return notificationURL;
  }
  const accountPath = getSSOAccountPath({ ssoAccountId, user });
  if (accountPath) {
    if (ssoConversationId) {
      return frontendURL(`${accountPath}/conversations/${ssoConversationId}`);
    }
    return frontendURL(`${accountPath}/dashboard`);
  }
  return DEFAULT_REDIRECT_URL;
};
