<script>
import { useVuelidate } from '@vuelidate/core';
import { required, minLength } from '@vuelidate/validators';
import { useAlert } from 'dashboard/composables';
import FormInput from '../../../components/Form/Input.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import { DEFAULT_REDIRECT_URL } from 'dashboard/constants/globals';
import { setNewPassword } from '../../../api/auth';
import { isToybacoPasswordValid, toybacoPasswordRequirements } from 'shared/helpers/toybacoPasswordRules';
import ToybacoPasswordRequirements from 'shared/components/ToybacoPasswordRequirements.vue';

export default {
  components: {
    FormInput,
    NextButton,
    ToybacoPasswordRequirements,
  },
  props: {
    resetPasswordToken: { type: String, default: '' },
  },
  setup() {
    return { v$: useVuelidate() };
  },
  data() {
    return {
      // We need to initialize the component with any
      // properties that will be used in it
      credentials: {
        confirmPassword: '',
        password: '',
      },
      newPasswordAPI: {
        message: '',
        showLoading: false,
      },
      error: '',
      linkExpired: false,
    };
  },
  computed: {
    passwordErrorMessage() {
      const password = this.v$.credentials.password;
      if (!password.$error) return '';
      const unmet = toybacoPasswordRequirements(this.credentials.password)
        .filter(item => !item.met)
        .map(item => item.id);
      // IME の全角など使えない文字は、短すぎるより先に伝える(空入力の allowed 未達は「短すぎる」に任せる)。
      if (this.credentials.password && unmet.includes('allowed')) {
        return '半角の英数字と記号だけを使ってください';
      }
      if (password.required.$invalid || password.minLength.$invalid) {
        return this.$t('SET_NEW_PASSWORD.PASSWORD.ERROR');
      }
      if (unmet.includes('length')) return '128 文字以内にしてください';
      return this.$t('REGISTER.PASSWORD.IS_INVALID_PASSWORD');
    },
  },
  mounted() {
    // If url opened without token
    // redirect to login
    if (!this.resetPasswordToken) {
      window.location = DEFAULT_REDIRECT_URL;
    }
  },
  validations: {
    credentials: {
      password: {
        required,
        minLength: minLength(6),
        isToybacoPasswordValid,
      },
      confirmPassword: {
        required,
        minLength: minLength(6),
        isEqPassword(value) {
          if (value !== this.credentials.password) {
            return false;
          }
          return true;
        },
      },
    },
  },
  methods: {
    showAlertMessage(message) {
      // Reset loading, current selected agent
      this.newPasswordAPI.showLoading = false;
      useAlert(message);
    },
    submitForm() {
      this.v$.$touch();
      if (this.v$.$invalid) return;
      this.newPasswordAPI.showLoading = true;
      const credentials = {
        confirmPassword: this.credentials.confirmPassword,
        password: this.credentials.password,
        resetPasswordToken: this.resetPasswordToken,
      };
      setNewPassword(credentials)
        .then(() => {
          window.location = DEFAULT_REDIRECT_URL;
        })
        .catch(error => {
          this.linkExpired = error?.errorCode === 'invalid_token';
          this.showAlertMessage(
            error?.message || this.$t('SET_NEW_PASSWORD.API.ERROR_MESSAGE')
          );
        });
    },
  },
};
</script>

<template>
  <div
    class="flex flex-col justify-center w-full min-h-screen py-12 bg-n-brand/5 dark:bg-n-background sm:px-6 lg:px-8"
  >
    <form
      class="bg-white shadow sm:mx-auto sm:w-full sm:max-w-lg dark:bg-n-solid-2 p-11 sm:shadow-lg sm:rounded-lg"
      @submit.prevent="submitForm"
    >
      <h1
        class="mb-1 text-2xl font-medium tracking-tight text-left text-n-slate-12"
      >
        {{ $t('SET_NEW_PASSWORD.TITLE') }}
      </h1>

      <div class="space-y-5">
        <div>
          <FormInput
            v-model="credentials.password"
            class="mt-3"
            name="password"
            type="password"
            aria-describedby="toybaco-password-requirements"
            :has-error="v$.credentials.password.$error"
            :error-message="passwordErrorMessage"
            :placeholder="$t('SET_NEW_PASSWORD.PASSWORD.PLACEHOLDER')"
            @blur="v$.credentials.password.$touch"
          />
          <ToybacoPasswordRequirements :password="credentials.password" />
        </div>
        <FormInput
          v-model="credentials.confirmPassword"
          class="mt-3"
          name="confirm_password"
          type="password"
          :has-error="v$.credentials.confirmPassword.$error"
          :error-message="$t('SET_NEW_PASSWORD.CONFIRM_PASSWORD.ERROR')"
          :placeholder="$t('SET_NEW_PASSWORD.CONFIRM_PASSWORD.PLACEHOLDER')"
          @blur="v$.credentials.confirmPassword.$touch"
        />
        <p v-if="linkExpired" role="status" class="text-sm text-n-ruby-11">
          このリンクは無効か、すでに使用済みです。<a href="/app/auth/reset/password" class="underline underline-offset-4">パスワード再設定メールを受け取る</a>
        </p>
        <NextButton
          lg
          type="submit"
          data-testid="submit_button"
          class="w-full"
          :label="$t('SET_NEW_PASSWORD.SUBMIT')"
          :disabled="
            v$.credentials.password.$invalid ||
            v$.credentials.confirmPassword.$invalid ||
            newPasswordAPI.showLoading
          "
          :is-loading="newPasswordAPI.showLoading"
        />
      </div>
    </form>
  </div>
</template>
