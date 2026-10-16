import { sendMessage } from 'widget/helpers/utils';
import ContactsAPI from '../../api/contacts';
import { SET_USER_ERROR } from '../../constants/errorTypes';
import { setHeader } from '../../helpers/axios';
const state = {
  currentUser: {},
};

const SET_CURRENT_USER = 'SET_CURRENT_USER';
const parseErrorData = error =>
  error && error.response && error.response.data ? error.response.data : error;
export const updateWidgetAuthToken = (widgetAuthToken, identityChanged = false) => {
  if (widgetAuthToken) {
    if (window.toybacoHttpSession && identityChanged) {
      window.toybacoWidgetIdentityGeneration = (window.toybacoWidgetIdentityGeneration || 0) + 1;
    }
    setHeader(widgetAuthToken);
    if (window.toybacoHttpSession) {
      if (identityChanged && window.toybacoHttpSessionPersisted) sendMessage({ event: 'http-session-identity-changed' });
      return;
    }
    sendMessage({
      event: 'setAuthCookie',
      data: { widgetAuthToken },
    });
  }
};

const performSetUser = async ({ dispatch, widgetIdentityOperation: operation }, { identifier, user: userObject }) => {
  try {
    const {
      email,
      name,
      avatar_url,
      identifier_hash: identifierHash,
      phone_number,
      company_name,
      city,
      country_code,
      description,
      custom_attributes,
      social_profiles,
    } = userObject;
    const user = {
      email,
      name,
      avatar_url,
      identifier_hash: identifierHash,
      phone_number,
      additional_attributes: {
        company_name,
        city,
        description,
        country_code,
        social_profiles,
      },
      custom_attributes,
    };
    const {
      data: { widget_auth_token: widgetAuthToken, widget_http_identity_changed: identityChanged },
    } = await ContactsAPI.setUser(identifier, user);
    if (window.toybacoHttpSession && operation !== window.toybacoWidgetOperationGeneration) return;
    updateWidgetAuthToken(widgetAuthToken, identityChanged === true);
    dispatch('get');
    if (identifierHash || widgetAuthToken) {
      dispatch('conversation/clearConversations', {}, { root: true });
      dispatch('conversation/fetchOldConversations', {}, { root: true });
      dispatch('conversationAttributes/getAttributes', {}, { root: true });
    }
  } catch (error) {
    if (window.toybacoHttpSession && operation !== window.toybacoWidgetOperationGeneration) return;
    const data = parseErrorData(error);
    sendMessage({ event: 'error', errorType: SET_USER_ERROR, data });
  }
};

export const getters = {
  getCurrentUser(_state) {
    return _state.currentUser;
  },
};

export const actions = {
  get: async ({ commit }) => {
    try {
      const { data } = await ContactsAPI.get();
      commit(SET_CURRENT_USER, data);
    } catch (error) {
      // Ignore error
    }
  },
  update: async ({ dispatch }, { user }) => {
    try {
      await ContactsAPI.update(user);
      dispatch('get');
    } catch (error) {
      // Ignore error
    }
  },
  setUser: performSetUser,
  setCustomAttributes: async (_, customAttributes = {}) => {
    try {
      await ContactsAPI.setCustomAttributes(customAttributes);
    } catch (error) {
      // Ignore error
    }
  },
  deleteCustomAttribute: async (_, customAttribute) => {
    try {
      await ContactsAPI.deleteCustomAttribute(customAttribute);
    } catch (error) {
      // Ignore error
    }
  },
};

export const mutations = {
  [SET_CURRENT_USER]($state, user) {
    const { currentUser } = $state;
    $state.currentUser = { ...currentUser, ...user };
  },
};

export default {
  namespaced: true,
  state,
  getters,
  actions,
  mutations,
};
