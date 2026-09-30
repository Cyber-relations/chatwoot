import QRCode from 'qrcode';

const canvas = document.getElementById('toybaco-mfa-qr');
if (canvas?.dataset.uri) {
  QRCode.toCanvas(canvas, canvas.dataset.uri, { width: 256, margin: 2 }).catch(
    () => {
      canvas.hidden = true;
      document.querySelector('details')?.setAttribute('open', '');
    }
  );
  delete canvas.dataset.uri;
}
