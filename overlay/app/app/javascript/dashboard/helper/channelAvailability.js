// The server supplies the same product switches used by creation and webhooks.
// Missing config must fail closed, including old/cached dashboard boot data.
export const isToybacoChannelAvailable = type => {
  const channel = {
    sms: 'sms',
    twilio: 'sms',
    voice: 'sms',
    whatsapp: 'whatsapp',
    whatsapp_call: 'whatsapp',
    twitter: 'twitter',
    twitter_profile: 'twitter',
  }[type];
  return !channel || window.chatwootConfig?.toybacoChannels?.[channel] === true;
};
