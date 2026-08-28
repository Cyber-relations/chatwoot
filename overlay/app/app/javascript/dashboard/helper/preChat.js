import i18n from 'widget/i18n/index';
const defaultTranslations = i18n.ja;

export const standardFieldKeys = {
  emailAddress: {
    key: 'EMAIL_ADDRESS',
    label: 'メールアドレス',
    placeholder: 'メールアドレスを入力してください',
  },
  fullName: {
    key: 'FULL_NAME',
    label: '氏名',
    placeholder: '氏名を入力してください',
  },
  phoneNumber: {
    key: 'PHONE_NUMBER',
    label: '電話番号',
    placeholder: '電話番号を入力してください',
  },
};

export const getLabel = ({ key, label }) => {
  return defaultTranslations.PRE_CHAT_FORM.FIELDS[key]
    ? defaultTranslations.PRE_CHAT_FORM.FIELDS[key].LABEL
    : label;
};
export const getPlaceHolder = ({ key, placeholder }) => {
  return defaultTranslations.PRE_CHAT_FORM.FIELDS[key]
    ? defaultTranslations.PRE_CHAT_FORM.FIELDS[key].PLACEHOLDER
    : placeholder;
};

export const getCustomFields = ({ standardFields, customAttributes }) => {
  let customFields = [];
  const { pre_chat_fields: preChatFields } = standardFields;
  customAttributes.forEach(attribute => {
    const itemExist = preChatFields.find(
      item => item.name === attribute.attribute_key
    );
    if (!itemExist) {
      customFields.push({
        label: attribute.attribute_display_name,
        placeholder: attribute.attribute_display_name,
        name: attribute.attribute_key,
        type: attribute.attribute_display_type,
        values: attribute.attribute_values,
        field_type: attribute.attribute_model,
        regex_pattern: attribute.regex_pattern,
        regex_cue: attribute.regex_cue,
        required: false,
        enabled: false,
      });
    }
  });
  return customFields;
};

export const getFormattedPreChatFields = ({ preChatFields }) => {
  return preChatFields.map(item => {
    return {
      ...item,
      label: getLabel({
        key: item.name,
        label: item.label ? item.label : item.name,
      }),
      placeholder: getPlaceHolder({
        key: item.name,
        placeholder: item.placeholder ? item.placeholder : item.name,
      }),
    };
  });
};

export const getPreChatFields = ({
  preChatFormOptions = {},
  customAttributes = [],
}) => {
  const { pre_chat_message, pre_chat_fields } = preChatFormOptions;
  let customFields = {};
  let preChatFields = {};

  const formattedPreChatFields = getFormattedPreChatFields({
    preChatFields: pre_chat_fields,
  });

  customFields = getCustomFields({
    standardFields: { pre_chat_fields: formattedPreChatFields },
    customAttributes,
  });
  preChatFields = [...formattedPreChatFields, ...customFields];

  return {
    pre_chat_message,
    pre_chat_fields: preChatFields,
  };
};
