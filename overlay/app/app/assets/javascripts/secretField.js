// eslint-disable-next-line
function toggleSecretField(e, target = e.currentTarget) {
  e.preventDefault();
  e.stopPropagation();

  const toggler = target;
  const secretField = toggler.parentElement;
  const textElement = secretField.querySelector('[data-secret-masked]');

  if (!textElement) return;

  if (textElement.dataset.secretMasked === 'false') {
    const maskedLength = secretField.dataset.secretText?.length || 10;
    textElement.textContent = '•'.repeat(maskedLength);
    textElement.dataset.secretMasked = 'true';
    toggler.querySelector('svg use').setAttribute('xlink:href', '#eye-show');

    return;
  }

  textElement.textContent = secretField.dataset.secretText;
  textElement.dataset.secretMasked = 'false';
  toggler.querySelector('svg use').setAttribute('xlink:href', '#eye-hide');
}

// eslint-disable-next-line
function copySecretField(e, target = e.currentTarget) {
  e.preventDefault();
  e.stopPropagation();

  const toggler = target;
  const secretField = toggler.parentElement;

  navigator.clipboard.writeText(secretField.dataset.secretText);
}

document.addEventListener('DOMContentLoaded', () => {
  document.querySelectorAll('.cell-data__secret-field').forEach(field => {
    const span = field.querySelector('[data-secret-masked]');
    if (span && span.dataset.secretMasked === 'true') {
      const len = field.dataset.secretText?.length || 10;
      span.textContent = '•'.repeat(len);
    }
  });
});

// A partial may include this asset repeatedly. Delegate once, including later rows.
if (!window.toybacoSecretFieldEventsBound) {
  window.toybacoSecretFieldEventsBound = true;
  document.addEventListener('click', event => {
    const button = event.target.closest?.('[data-secret-toggler], [data-secret-copier], [data-toybaco-support-mail]');
    if (!button) return;
    if (button.hasAttribute('data-secret-toggler')) toggleSecretField(event, button);
    else if (button.hasAttribute('data-secret-copier')) copySecretField(event, button);
    else window.location.href = 'mailto:support@toybaco.jp';
  });
}
