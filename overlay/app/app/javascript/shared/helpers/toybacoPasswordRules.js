// トイバコ: パスワード要件の唯一の定義。devise-secure_password 2.2.1(Support::String::CharacterCounter)と同じ規則:
// 6〜128 文字、英大文字・英小文字・数字・記号(空白を含む)を各 1 文字以上、それ以外の文字(全角・絵文字など)は使えない。
// 画面の要件チェックリスト・クライアント側検証・422 本文の扱いで使う。import を持たない純 JS(node テストが data: URL で import する)。
export const TOYBACO_PASSWORD_MIN_LENGTH = 6;
export const TOYBACO_PASSWORD_MAX_LENGTH = 128;
// gem(devise-secure_password 2.2.1 の Support::String::CharacterCounter)と同じ記号集合。先頭の空白も記号。
export const TOYBACO_PASSWORD_SPECIAL_PATTERN = /[ !@#$%^&*()_+\-=[\]{}|'"/\\.,`<>:;?~]/;
// gem が数えられる文字だけ(英大小・数字・上の記号)。それ以外(全角・絵文字など)は unknown として 422 になる。
export const TOYBACO_PASSWORD_ALLOWED_PATTERN = /^[A-Za-z0-9 !@#$%^&*()_+\-=[\]{}|'"/\\.,`<>:;?~]*$/;

export const toybacoPasswordRequirements = (password = '') => {
  const value = typeof password === 'string' ? password : '';
  return [
    {
      id: 'length',
      key: 'REGISTER.PASSWORD.REQUIREMENTS_LENGTH',
      met:
        value.length >= TOYBACO_PASSWORD_MIN_LENGTH &&
        value.length <= TOYBACO_PASSWORD_MAX_LENGTH,
    },
    {
      id: 'uppercase',
      key: 'REGISTER.PASSWORD.REQUIREMENTS_UPPERCASE',
      met: /[A-Z]/.test(value),
    },
    {
      id: 'lowercase',
      key: 'REGISTER.PASSWORD.REQUIREMENTS_LOWERCASE',
      met: /[a-z]/.test(value),
    },
    {
      id: 'number',
      key: 'REGISTER.PASSWORD.REQUIREMENTS_NUMBER',
      met: /[0-9]/.test(value),
    },
    {
      id: 'special',
      key: 'REGISTER.PASSWORD.REQUIREMENTS_SPECIAL',
      met: TOYBACO_PASSWORD_SPECIAL_PATTERN.test(value),
    },
    {
      id: 'allowed',
      label: '半角の英数字と記号のみ',
      // 空入力では未達(他の行と同じく灰色)。
      met: value.length > 0 && TOYBACO_PASSWORD_ALLOWED_PATTERN.test(value),
    },
  ];
};

// vuelidate のルールとしても使う(空文字は false)。
export const isToybacoPasswordValid = password =>
  toybacoPasswordRequirements(password).every(r => r.met);

// サーバー文言を画面に出してよいか: 仮名漢字を含み、英字 3 連続を含まない。
// 属性名「パスワード」だけ日本語の英語混在文(旧サーバー・翻訳欠落)を通さない。
// ja の要件文言の英字は記号一覧と (A..Z)・(a..z)・(0..9) だけで、3 連続にならない。
export const isToybacoJapaneseMessage = text =>
  typeof text === 'string' &&
  /[ぁ-んァ-ヶ一-龠々ー]/.test(text) &&
  !/[A-Za-z]{3,}/.test(text);

// 422 の full_messages は password と password_confirmation に同じ要件文が付くので、確認用の重複文を落とす。
export const toybacoPasswordServerMessage = message =>
  message.split(', パスワード（確認） ')[0];
