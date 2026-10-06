/* Public free-registration analytics. Never read or transmit form values or authentication tokens. */
(() => {
  'use strict';
  const origin = 'https://app.staging.toybaco.jp';
  const paths = ['/toybaco/free/signup', '/toybaco/free/verify-email'];
  const marker = document.getElementById('free-registration-measurement');
  if (location.origin !== origin || !paths.includes(location.pathname) || !marker || window.toybacoFreeRegistrationMeasurement) return;
  const choiceKey = 'toybaco_free_registration_analytics_staging_v1';
  let choice = 'unset';
  try { choice = sessionStorage.getItem(choiceKey) || 'unset'; } catch (_) { /* Fail closed when storage is unavailable. */ }
  let active = choice === 'accepted';
  const page = location.pathname === paths[0] ? 'signup' : 'verify_email';
  // Neither query strings, fragment IDs, document titles nor input values enter the data layer.
  const context = {
    site_name: 'toybaco', service_name: 'toybaco', page_language: 'ja', content_type: 'registration',
    page_location: origin + location.pathname, page_referrer: '',
    page_title: page === 'signup' ? '無料ではじめる | トイバコ' : 'メールを確認 | トイバコ',
    measurement_test_mode: 'staging', measurement_consent: active ? 'accepted' : 'denied',
    measurement_cookie_prefix: 'tb_free_staging', measurement_debug: true,
    test_run: 'toybaco_free_registration_20261006',
    // Clear stale campaign data. No cross-origin identifier or arbitrary UTM is forwarded.
    campaign_source: null, campaign_medium: null, campaign_name: null, campaign_content: null, campaign_id: null
  };
  try {
    const ref = new URL(document.referrer);
    if (ref.origin === origin && paths.includes(ref.pathname)) context.page_referrer = origin + ref.pathname;
    else if (ref.origin === 'https://staging.toybaco.jp') context.page_referrer = ref.origin + '/';
  } catch (_) { /* Empty or unrelated referrer stays empty. */ }
  window.dataLayer = window.dataLayer || [];
  const consent = function() { window.dataLayer.push(arguments); };
  const pushConsent = status => consent('consent', status, {
    analytics_storage: active ? 'granted' : 'denied', ad_storage: 'denied', ad_user_data: 'denied', ad_personalization: 'denied'
  });
  pushConsent('default');
  window.dataLayer.push(context);
  const fields = { account_name: 'account_name', user_full_name: 'name', email: 'email', password: 'password', accept_terms: 'consent' };
  const errorTypes = ['validation', 'captcha', 'existing_account'];
  const emit = (event, errorType, errorField, callback) => {
    if (!active || !['free_signup_start', 'free_signup_submit', 'free_signup_request_accepted', 'form_error'].includes(event)) return false;
    if (event === 'form_error' && (!errorTypes.includes(errorType) || ![...Object.values(fields), 'form'].includes(errorField))) return false;
    window.dataLayer.push({ ...context, event, form_id: 'toybaco_free_registration', form_type: 'free_registration',
      error_type: event === 'form_error' ? errorType : null, error_field: event === 'form_error' ? errorField : null,
      eventCallback: callback, eventTimeout: callback ? 800 : undefined });
    return true;
  };
  const stop = () => {
    active = false;
    window['ga-disable-G-N18VE3LMRS'] = true;
    window['ga-disable-G-YR5P1YSG3G'] = true;
    pushConsent('update');
    window.dataLayer.push({ measurement_consent: 'denied' });
    for (const cookie of document.cookie.split(';')) {
      const name = cookie.trim().split('=')[0];
      if (/^tb_free_staging(?:_|$)/.test(name))
        document.cookie = name + '=; Max-Age=0; Path=/; SameSite=Lax; Secure';
    }
  };
  const setChoice = next => {
    if (!['accepted', 'denied'].includes(next)) return false;
    stop();
    try { sessionStorage.setItem(choiceKey, next); } catch (_) { return false; }
    location.reload();
    return true;
  };
  window.toybacoFreeRegistrationMeasurement = Object.freeze({ setChoice, get active() { return active; } });
  if (active) {
    window.dataLayer.push({ 'gtm.start': Date.now(), event: 'gtm.js' });
    const script = document.createElement('script');
    script.async = true;
    script.src = 'https://www.googletagmanager.com/gtm.js?id=GTM-T2ZGF6ZP';
    document.head.appendChild(script);
  }
  const form = document.getElementById('toybaco-free-registration');
  if (form && page === 'signup') {
    let started = false;
    const invalidFields = new Set();
    const start = e => {
      if (!e.isTrusted || !Object.hasOwn(fields, e.target.name) || started) return;
      if (emit('free_signup_start')) started = true;
    };
    form.addEventListener('input', e => { start(e); invalidFields.delete(e.target.name); });
    form.addEventListener('change', start);
    form.addEventListener('invalid', e => {
      if (!e.isTrusted || !Object.hasOwn(fields, e.target.name) || invalidFields.has(e.target.name)) return;
      if (emit('form_error', 'validation', fields[e.target.name])) invalidFields.add(e.target.name);
    }, true);
    form.addEventListener('submit', e => {
      if (!e.isTrusted || e.defaultPrevented || !active) return;
      // A bounded wait allows navigation events to be delivered; analytics never blocks registration.
      let sent = false;
      const proceed = () => {
        if (sent) return;
        sent = true;
        HTMLFormElement.prototype.submit.call(form);
      };
      e.preventDefault();
      setTimeout(proceed, 900);
      emit('free_signup_submit', null, null, proceed);
    });
  }
  if (page === 'signup' && errorTypes.includes(marker.dataset.error)) emit('form_error', marker.dataset.error, 'form');
  // This is request acceptance, not completed email confirmation or a usable account (GA4 sign_up).
  if (page === 'verify_email' && marker.dataset.requestAccepted === 'true') emit('free_signup_request_accepted');
  const panel = document.createElement('aside');
  panel.id = 'free-registration-analytics-controls';
  panel.setAttribute('aria-label', '登録画面の計測検証');
  panel.style.cssText = 'position:fixed;left:12px;bottom:12px;z-index:10001;max-width:calc(100vw - 24px);width:350px;padding:14px;border:1px solid #ccd4de;border-radius:12px;background:#fff;color:#162b40;font:13px/1.6 sans-serif;box-sizing:border-box;box-shadow:0 4px 24px #162b4020';
  const label = document.createElement('p');
  label.textContent = active ? '登録画面の計測検証：送信許可' : '登録画面の計測検証：送信停止';
  label.style.cssText = 'margin:0 0 8px';
  panel.appendChild(label);
  const help = document.createElement('p');
  help.textContent = 'QA用のアクセス解析です。入力内容は送信しません。登録の規約同意とは別の設定です。';
  help.style.cssText = 'margin:0 0 8px';
  panel.appendChild(help);
  for (const [value, text] of [['accepted', '解析のテストを許可'], ['denied', active ? '解析を停止' : '解析を許可しない']]) {
    const button = document.createElement('button');
    button.type = 'button'; button.textContent = text;
    button.style.cssText = 'width:auto;margin:0 6px 0 0;padding:8px 10px;font:inherit;cursor:pointer';
    button.addEventListener('click', () => { if (!setChoice(value)) label.textContent = '設定を保存できません。解析は停止しています。'; });
    panel.appendChild(button);
  }
  document.body.appendChild(panel);
})();
