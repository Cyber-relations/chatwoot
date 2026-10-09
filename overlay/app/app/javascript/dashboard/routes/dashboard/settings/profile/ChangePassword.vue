<script>
import { useVuelidate } from '@vuelidate/core';
import { required, minLength } from '@vuelidate/validators';
import { useAlert } from 'dashboard/composables';
import {
  isToybacoJapaneseMessage,
  isToybacoPasswordValid,
  toybacoPasswordRequirements,
  toybacoPasswordServerMessage,
} from 'shared/helpers/toybacoPasswordRules';
import ToybacoPasswordRequirements from 'shared/components/ToybacoPasswordRequirements.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';

export default {
  components: {
    NextButton,
    ToybacoPasswordRequirements,
  },
  setup() {
    return { v$: useVuelidate() };
  },
  data() {
    return {
      currentPassword: '',
      password: '',
      passwordConfirmation: '',
      isPasswordChanging: false,
      errorMessage: '',
      inputStyles: {
        borderRadius: '0.75rem',
        padding: '0.375rem 0.75rem',
        fontSize: '0.875rem',
        marginBottom: '0.125rem',
      },
    };
  },
  validations: {
    currentPassword: {
      required,
    },
    password: {
      required,
      minLength: minLength(6),
      isToybacoPasswordValid,
    },
    passwordConfirmation: {
      minLength: minLength(6),
      isEqPassword(value) {
        if (value !== this.password) {
          return false;
        }
        return true;
      },
    },
  },
  computed: {
    passwordErrorMessage() {
      const password = this.v$.password;
      if (!password.$error) return '';
      const unmet = toybacoPasswordRequirements(this.password)
        .filter(item => !item.met)
        .map(item => item.id);
      // IME の全角など使えない文字は、短すぎるより先に伝える(空入力の allowed 未達は「短すぎる」に任せる)。
      if (this.password && unmet.includes('allowed')) {
        return '半角の英数字と記号だけを使ってください';
      }
      if (password.required.$invalid || password.minLength.$invalid) {
        return this.$t('PROFILE_SETTINGS.FORM.PASSWORD.ERROR');
      }
      if (unmet.includes('length')) return '128 文字以内にしてください';
      return this.$t('REGISTER.PASSWORD.IS_INVALID_PASSWORD');
    },
    isButtonDisabled() {
      return (
        !this.currentPassword ||
        !this.passwordConfirmation ||
        this.v$.passwordConfirmation.$invalid ||
        this.v$.password.$invalid
      );
    },
  },
  methods: {
    toybacoPasswordAlert(error) {
      const data = error?.response?.data;
      if (error?.response?.status === 422 && data?.error === 'Invalid current password') {
        return '現在のパスワードが正しくありません。';
      }
      const message = typeof data?.message === 'string' ? data.message : '';
      if (error?.response?.status === 422 && isToybacoJapaneseMessage(message)) {
        return toybacoPasswordServerMessage(message);
      }
      return this.$t('RESET_PASSWORD.API.ERROR_MESSAGE');
    },
    async changePassword() {
      this.v$.$touch();
      if (this.v$.$invalid) {
        useAlert(this.$t('PROFILE_SETTINGS.FORM.ERROR'));
        return;
      }
      let alertMessage = this.$t('PROFILE_SETTINGS.PASSWORD_UPDATE_SUCCESS');
      try {
        await this.$store.dispatch('updatePassword', {
          password: this.password,
          passwordConfirmation: this.passwordConfirmation,
          currentPassword: this.currentPassword,
        });
      } catch (error) {
        alertMessage = this.toybacoPasswordAlert(error);
      } finally {
        useAlert(alertMessage);
      }
    },
  },
};
</script>

<template>
  <form @submit.prevent="changePassword()">
    <div class="flex flex-col w-full gap-4">
      <woot-input
        v-model="currentPassword"
        type="password"
        :styles="inputStyles"
        :class="{ error: v$.currentPassword.$error }"
        :label="$t('PROFILE_SETTINGS.FORM.CURRENT_PASSWORD.LABEL')"
        :placeholder="$t('PROFILE_SETTINGS.FORM.CURRENT_PASSWORD.PLACEHOLDER')"
        :error="`${
          v$.currentPassword.$error
            ? $t('PROFILE_SETTINGS.FORM.CURRENT_PASSWORD.ERROR')
            : ''
        }`"
        @input="v$.currentPassword.$touch"
        @blur="v$.currentPassword.$touch"
      />

      <div>
        <woot-input
          v-model="password"
          type="password"
          :styles="inputStyles"
          :class="{ error: v$.password.$error }"
          :label="$t('PROFILE_SETTINGS.FORM.PASSWORD.LABEL')"
          :placeholder="$t('PROFILE_SETTINGS.FORM.PASSWORD.PLACEHOLDER')"
          :error="passwordErrorMessage"
          @input="v$.password.$touch"
          @blur="v$.password.$touch"
        />
        <ToybacoPasswordRequirements :password="password" />
      </div>

      <woot-input
        v-model="passwordConfirmation"
        type="password"
        :styles="inputStyles"
        :class="{ error: v$.passwordConfirmation.$error }"
        :label="$t('PROFILE_SETTINGS.FORM.PASSWORD_CONFIRMATION.LABEL')"
        :placeholder="
          $t('PROFILE_SETTINGS.FORM.PASSWORD_CONFIRMATION.PLACEHOLDER')
        "
        :error="`${
          v$.passwordConfirmation.$error
            ? $t('PROFILE_SETTINGS.FORM.PASSWORD_CONFIRMATION.ERROR')
            : ''
        }`"
        @input="v$.passwordConfirmation.$touch"
        @blur="v$.passwordConfirmation.$touch"
      />

      <div>
        <NextButton
          type="submit"
          :label="$t('PROFILE_SETTINGS.FORM.PASSWORD_SECTION.BTN_TEXT')"
          :disabled="isButtonDisabled"
        />
      </div>
    </div>
  </form>
</template>
