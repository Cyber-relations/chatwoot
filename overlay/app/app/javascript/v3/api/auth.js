import {
  setAuthCredentials,
  clearLocalStorageOnLogout,
  parseAPIErrorResponse,
} from 'dashboard/store/utils/api';
import wootAPI from './apiClient';
import { isToybacoJapaneseMessage, toybacoPasswordServerMessage } from 'shared/helpers/toybacoPasswordRules';
import {
  getLoginRedirectURL,
  getCredentialsFromEmail,
} from '../helpers/AuthHelper';

export const login = async ({
  ssoAccountId,
  ssoConversationId,
  ...credentials
}) => {
  try {
    const response = await wootAPI.post('auth/sign_in', credentials);

    if (response.status === 206 && response.data.mfa_enrollment_required) {
      window.location = '/toybaco/mfa-enrollment';
      return null;
    }

    // Check if MFA is required
    if (response.status === 206 && response.data.mfa_required) {
      // Return MFA data instead of throwing error
      return {
        mfaRequired: true,
        mfaToken: response.data.mfa_token,
      };
    }

    setAuthCredentials(response);
    clearLocalStorageOnLogout();
    window.location = getLoginRedirectURL({
      ssoAccountId,
      ssoConversationId,
      user: response.data.data,
    });
    return null;
  } catch (error) {
    // Check if it's an MFA required response
    if (error.response?.status === 206 && error.response?.data?.mfa_required) {
      return {
        mfaRequired: true,
        mfaToken: error.response.data.mfa_token,
      };
    }
    if (
      error.response?.status === 409 &&
      error.response?.data?.sessions_limit_reached
    ) {
      return {
        sessionsLimitReached: true,
        sessions: error.response.data.sessions,
      };
    }
    const parsedError = parseAPIErrorResponse(error);
    const loginError = new Error(
      typeof parsedError === 'string' && /[ぁ-んァ-ヶ一-龠々ー]/.test(parsedError)
        ? parsedError
        : 'ログインできませんでした。入力内容を確認して、もう一度お試しください。'
    );
    loginError.errorCode = error.response?.data?.error_code;
    throw loginError;
  }
};

export const register = async creds => {
  try {
    const { fullName, accountName } = getCredentialsFromEmail(creds.email);
    const response = await wootAPI.post('api/v1/accounts.json', {
      account_name: accountName,
      user_full_name: fullName,
      email: creds.email,
      password: creds.password,
      h_captcha_client_response: creds.hCaptchaClientResponse,
    });
    return response.data;
  } catch (error) {
    throw new Error('操作を完了できませんでした。もう一度お試しください。');
  }
  return null;
};

export const resendConfirmation = async ({ email, hCaptchaClientResponse }) => {
  return wootAPI.post('resend_confirmation', {
    email,
    h_captcha_client_response: hCaptchaClientResponse,
  });
};

export const verifyPasswordToken = async ({ confirmationToken }) => {
  try {
    const response = await wootAPI.post('auth/confirmation', {
      confirmation_token: confirmationToken,
    });
    setAuthCredentials(response);
  } catch (error) {
    throw new Error('操作を完了できませんでした。もう一度お試しください。');
  }
};

// auth/password の失敗理由を日本語だけで返す。サーバー文言は仮名漢字あり・英字 3 連続なしのときだけ通し(英語の混在を出さない)、
// 確認用の重複文を落とす。
const TOYBACO_PASSWORD_LINK_EXPIRED =
  'このリンクは無効か、すでに使用済みです。ログイン画面の「パスワードを忘れた場合」から新しいメールを受け取ってください。';
const TOYBACO_PASSWORD_GENERIC = '操作を完了できませんでした。もう一度お試しください。';
const toybacoPasswordError = error => {
  const status = error?.response?.status;
  const data = error?.response?.data;
  const message = typeof data?.message === 'string' ? data.message : '';
  if (status === 422 && message === 'Invalid token') {
    const expired = new Error(TOYBACO_PASSWORD_LINK_EXPIRED);
    expired.errorCode = 'invalid_token';
    return expired;
  }
  if (status === 422 && isToybacoJapaneseMessage(message)) {
    const invalid = new Error(toybacoPasswordServerMessage(message));
    invalid.errorCode = 'invalid_password';
    return invalid;
  }
  return new Error(TOYBACO_PASSWORD_GENERIC);
};

export const setNewPassword = async ({
  resetPasswordToken,
  password,
  confirmPassword,
}) => {
  try {
    const response = await wootAPI.put('auth/password', {
      reset_password_token: resetPasswordToken,
      password_confirmation: confirmPassword,
      password,
    });
    setAuthCredentials(response);
  } catch (error) {
    throw toybacoPasswordError(error);
  }
};

export const resetPassword = async ({ email }) =>
  wootAPI.post('auth/password', { email });
