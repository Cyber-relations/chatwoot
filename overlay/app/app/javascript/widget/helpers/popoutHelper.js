import { openHttpPopout } from './httpPopout';

export const popoutChatWindow = (origin, websiteToken, locale) =>
  openHttpPopout(origin, websiteToken, locale);
