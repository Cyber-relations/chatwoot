import { buildPopoutURL } from './urlParamsHelper';
import { openHttpPopout } from './httpPopout';

export const popoutChatWindow = (
  origin,
  websiteToken,
  locale,
  conversationCookie
) => {
  if (window.toybacoHttpSession) return openHttpPopout(origin, websiteToken, locale);
  try {
    const windowUrl = buildPopoutURL({
      origin,
      websiteToken,
      locale,
      conversationCookie,
    });
    const popoutWindow = window.open(
      windowUrl,
      `webwidget_session_${websiteToken}`,
      'resizable=off,width=400,height=600'
    );
    popoutWindow.focus();
  } catch (err) {
    // eslint-disable-next-line no-console
    console.log(err);
  }
};
