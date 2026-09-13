import { createRouter, createWebHistory } from 'vue-router';

import { frontendURL } from '../helper/URLHelper';
import dashboard from './dashboard/dashboard.routes';
import store from 'dashboard/store';
import { validateLoggedInRoutes } from '../helper/routeHelpers';
import { isOnOnboardingView } from 'v3/helpers/RouteHelper';
import { getNotificationLoginURL } from 'v3/helpers/AuthHelper';
import AnalyticsHelper from '../helper/AnalyticsHelper';

const ONBOARDING_STEPS = ['account_details', 'enrichment', 'inbox_setup'];
const routes = [...dashboard.routes];

const onboardingPath = step =>
  step === 'inbox_setup' ? 'onboarding/inbox-setup' : 'onboarding';

export const router = createRouter({ history: createWebHistory(), routes });

// The posting overlay owns its hash without changing the underlying Vue route.
// Use RouterHistory so native back/forward also sees its current location and
// position cache; raw pushState would update only the browser's copy.
const writePostingHistory = event => {
  const detail = event.detail;
  if (!detail || typeof detail !== 'object') return;
  // Once the router exists, the overlay must never fall back to raw History.
  detail.handled = true;
  const { hash, replace } = detail;
  if (typeof hash !== 'string' || typeof replace !== 'boolean') return;
  if (hash) {
    const prefix = '#/toybaco/posting?path=';
    if (!hash.startsWith(prefix)) return;
    try {
      const encodedPath = hash.slice(prefix.length);
      const path = decodeURIComponent(encodedPath);
      const pathname = path.split('?', 1)[0];
      if (
        path.length > 2000 || encodeURIComponent(path) !== encodedPath ||
        !/^\/[A-Za-z0-9._~/?=&-]*$/.test(path) ||
        !/^\/(launches|analytics|media|settings)(\/|$)/.test(pathname) ||
        pathname.split('/').some(segment => segment === '.' || segment === '..') ||
        /^\/settings\/templates(\/|$)/.test(pathname)
      ) return;
    } catch {
      return;
    }
  }
  const target = window.location.pathname + window.location.search + hash;
  router.options.history[replace ? 'replace' : 'push'](target, {
    toybacoPosting: Boolean(hash),
  });
};
if (typeof window !== 'undefined' && typeof window.addEventListener === 'function') {
  window.addEventListener('toybaco:posting-history', writePostingHistory);
}

export const validateAuthenticateRoutePermission = async (to, next) => {
  const { isLoggedIn, getCurrentUser: user } = store.getters;

  if (!isLoggedIn) {
    window.location.assign(getNotificationLoginURL(to.path));
    return '';
  }

  const { accounts = [], account_id: accountId } = user;

  if (!accounts.length) {
    if (to.name === 'no_accounts') {
      return next();
    }
    return next(frontendURL('no-accounts'));
  }

  const routeAccountId = Number(to.params?.accountId || accountId);
  const userAccount = accounts.find(a => a.id === routeAccountId);
  const isAdmin = userAccount?.role === 'administrator';
  const isActive = userAccount?.status === 'active';
  const needsOnboarding =
    ONBOARDING_STEPS.includes(userAccount?.onboarding_step) &&
    isAdmin &&
    isActive;

  if (to.name === 'no_accounts' || !to.name) {
    const target = needsOnboarding
      ? onboardingPath(userAccount?.onboarding_step)
      : 'dashboard';
    return next(frontendURL(`accounts/${routeAccountId}/${target}`));
  }

  if (needsOnboarding && !isOnOnboardingView(to)) {
    return next(
      frontendURL(
        `accounts/${routeAccountId}/${onboardingPath(userAccount?.onboarding_step)}`
      )
    );
  }
  if (!needsOnboarding && isOnOnboardingView(to)) {
    return next(frontendURL(`accounts/${routeAccountId}/dashboard`));
  }

  const nextRoute = validateLoggedInRoutes(to, store.getters.getCurrentUser);
  return nextRoute ? next(frontendURL(nextRoute)) : next();
};

export const initalizeRouter = () => {
  const userAuthentication = store.dispatch('setUser');

  router.beforeEach(async (to, _from, next) => {
    AnalyticsHelper.page(to.name || '', {
      path: to.path,
      name: to.name,
    });

    await userAuthentication;
    await validateAuthenticateRoutePermission(to, next, store);
  });
};

export default router;
