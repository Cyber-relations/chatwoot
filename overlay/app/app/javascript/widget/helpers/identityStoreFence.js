import { runIdentityOperation } from './identityOperations';

const generation = () => window.toybacoWidgetIdentityGeneration || 0;
const privateModules = new Set(['contacts', 'conversation', 'conversationAttributes', 'conversationLabels', 'message', 'campaign', 'events']);
const identityActions = new Set(['contacts/setUser', 'contacts/update', 'contacts/setCustomAttributes',
  'contacts/deleteCustomAttribute', 'conversation/createConversation', 'message/update']);
// These two callers submit attributes only; the fixed controller's identify
// action has no identifier/email/phone with which to rebind the contact.
const attributeOnlyActions = new Set(['contacts/setCustomAttributes', 'contacts/deleteCustomAttribute']);
const historyLoadingOwners = new WeakMap();
const hasIdentityValue = value => value !== undefined && value !== null &&
  (typeof value !== 'string' || value.trim().length > 0);
const nonIdentifyingOperation = (path, input) => {
  if (attributeOnlyActions.has(path)) return true;
  if (!input || typeof input !== 'object') return false;
  // The actual MessageAPI puts email in contact.email; submitted_values do
  // not identify a contact. Keep the email-input fence, not a blanket bypass.
  if (path === 'message/update') return !hasIdentityValue(input.email);
  if (path === 'contacts/update' && input.user && typeof input.user === 'object') {
    return ['identifier', 'email', 'phone_number'].every(key => !hasIdentityValue(input.user[key]));
  }
  return false;
};

const guardAction = (action, path) => {
  const handler = typeof action === 'function' ? action : action.handler;
  if (typeof handler !== 'function') return action;
  const guarded = function guardedIdentityAction(context, ...args) {
    const execute = operation => {
      const historyLoad = path === 'conversation/fetchOldConversations';
      const loadingOwner = {};
      const started = window.toybacoHttpSession ? generation() : undefined;
      const current = () => operation === undefined
        ? started === undefined || started === generation()
        : operation === window.toybacoWidgetOperationGeneration && operation === window.toybacoWidgetActiveOperation;
      const safeContext = {
        ...context,
        widgetIdentityOperation: operation,
        commit: (...values) => {
          if (historyLoad && values[0] === 'setConversationListLoading' && typeof values[1] === 'boolean') {
            // Old data is still refused. Only the request that owns this UI
            // flag can release it, including after an identity invalidation.
            if (values[1] && current()) {
              historyLoadingOwners.set(context.state, loadingOwner);
              context.commit(...values);
            } else if (!values[1] && historyLoadingOwners.get(context.state) === loadingOwner) {
              historyLoadingOwners.delete(context.state);
              context.commit(...values);
            }
            return;
          }
          if (current()) context.commit(...values);
        },
        dispatch: (...values) => current() ? context.dispatch(...values) : Promise.resolve(),
      };
      return handler.call(this, safeContext, ...args);
    };
    return identityActions.has(path)
      ? runIdentityOperation(execute, { invalidateReads: !nonIdentifyingOperation(path, args[0]) }) : execute(undefined);
  };
  return typeof action === 'function' ? guarded : { ...action, handler: guarded };
};

export const guardWidgetModules = (modules, prefix = '') => Object.fromEntries(
  Object.entries(modules).map(([name, module]) => {
    if (!prefix && !privateModules.has(name)) return [name, module];
    const path = prefix ? `${prefix}/${name}` : name;
    return [name, {
      ...module,
      ...(module.actions ? { actions: Object.fromEntries(Object.entries(module.actions)
        .map(([action, handler]) => [action, guardAction(handler, `${path}/${action}`)])) } : {}),
      ...(module.modules ? { modules: guardWidgetModules(module.modules, path) } : {}),
    }];
  })
);
