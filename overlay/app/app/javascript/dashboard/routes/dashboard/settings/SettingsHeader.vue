<script>
import { useAdmin } from 'dashboard/composables/useAdmin';
import BackButton from '../../../components/widgets/BackButton.vue';

export default {
  components: {
    BackButton,
  },
  props: {
    headerTitle: {
      default: '',
      type: String,
    },
    icon: {
      default: '',
      type: String,
    },
    showBackButton: { type: Boolean, default: false },
    backUrl: {
      type: [String, Object],
      default: '',
    },
    backButtonLabel: {
      type: String,
      default: '',
    },
  },
  setup() {
    const { isAdmin } = useAdmin();
    return {
      isAdmin,
    };
  },
  computed: {
    iconClass() {
      return `icon ${this.icon} header--icon`;
    },
  },
};
</script>

<template>
  <div
    class="flex justify-between items-center h-auto min-h-14 px-4 py-2 bg-n-surface-1"
  >
    <h1
      class="flex flex-1 min-w-0 flex-wrap items-center gap-y-1 mb-0 text-[15px] leading-5 text-n-slate-12"
    >
      <BackButton
        v-if="showBackButton"
        :button-label="backButtonLabel"
        :back-url="backUrl"
        class="ltr:mr-2 rtl:ml-2"
      />

      <slot />
      <span
        class="min-w-0 break-words text-[15px] leading-5 font-semibold text-n-slate-12"
      >
        {{ headerTitle }}
      </span>
    </h1>
  </div>
</template>
