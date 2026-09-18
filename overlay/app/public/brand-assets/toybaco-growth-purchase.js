(() => {
  'use strict';
  const root = document.getElementById('purchase');
  if (!root || !/^[1-9]\d*$/.test(root.dataset.accountId)) return;
  const id = root.dataset.accountId;
  const element = (name) => document.getElementById(name);
  let busy = false;
  let state = null;
  const texts = {
    none: 'プランを選んでください。',
    expired: '先ほどの決済は終了しました。プランを選び直せます。',
    prepared: '先ほどの決済状況を確認してください。',
    open: '決済を再開するか、終了してプランを選び直せます。',
    payment_pending:
      '入金を確認しています。確認後、同じ店舗にプランを反映します。',
    complete: 'この店舗で有料プランが使えるようになりました。',
  };

  function render(result) {
    if (!result || !Object.hasOwn(texts, result.state))
      throw new Error('決済状況を確認できませんでした。');
    state = result;
    element('purchase-status').textContent = texts[result.state];
    element('purchase-selection').hidden = !['none', 'expired'].includes(
      result.state
    );
    element('pending-actions').hidden = ![
      'prepared',
      'open',
      'payment_pending',
    ].includes(result.state);
    element('purchase-resume').hidden = !['prepared', 'open'].includes(
      result.state
    );
    element('purchase-cancel').hidden = !['prepared', 'open'].includes(
      result.state
    );
    element('purchase-complete').hidden = result.state !== 'complete';
  }

  async function request(path, body, method = 'POST') {
    if (busy) return null;
    busy = true;
    root.querySelectorAll('button').forEach((button) => {
      button.disabled = true;
    });
    element('purchase-error').hidden = true;
    try {
      const response = await fetch(
        `${path}?account_id=${encodeURIComponent(id)}`,
        {
          method,
          credentials: 'same-origin',
          headers: {
            'Content-Type': 'application/json',
            Accept: 'application/json',
          },
          ...(body ? { body: JSON.stringify(body) } : {}),
        }
      );
      if ([401, 403].includes(response.status))
        throw new Error('契約者のアカウントで、もう一度開いてください。');
      const result = await response.json();
      if (!response.ok || response.redirected)
        throw new Error(result.error || '決済状況を確認できませんでした。');
      render(result);
      return result;
    } catch (error) {
      element('purchase-error').textContent = error.message;
      element('purchase-error').hidden = false;
      return null;
    } finally {
      busy = false;
      root.querySelectorAll('button').forEach((button) => {
        button.disabled = false;
      });
    }
  }

  function openCheckout(result) {
    if (result?.state !== 'open' || !result.url) return;
    const url = new URL(result.url);
    if (
      url.origin === 'https://checkout.stripe.com' &&
      !url.username &&
      !url.password
    )
      window.location.assign(url.href);
  }

  root.querySelectorAll('[data-purchase-plan]').forEach((button) => {
    button.addEventListener('click', async () => {
      const plan = button.closest('[data-plan-id]');
      const cycle = root.querySelector('input[name="cycle"]:checked').value;
      const selection = {
        plan_id: plan.dataset.planId,
        plan_version: plan.dataset.planVersion,
        cycle,
      };
      openCheckout(await request('/toybaco/growth/purchase', { selection }));
    });
  });
  root.querySelectorAll('input[name="cycle"]').forEach((input) =>
    input.addEventListener('change', () => {
      root.querySelectorAll('[data-cycle]').forEach((price) => {
        price.hidden = price.dataset.cycle !== input.value;
      });
    })
  );
  element('purchase-resume').addEventListener('click', async () => {
    if (state?.selection)
      openCheckout(
        await request('/toybaco/growth/purchase', {
          selection: state.selection,
        })
      );
  });
  element('purchase-refresh').addEventListener('click', () =>
    request('/toybaco/growth/purchase/refresh')
  );
  element('purchase-cancel').addEventListener('click', () =>
    request('/toybaco/growth/purchase/cancel')
  );
  request('/toybaco/growth/purchase/state', null, 'GET').then((result) => {
    if (result && !['none', 'expired', 'complete'].includes(result.state))
      request('/toybaco/growth/purchase/refresh');
  });
})();
