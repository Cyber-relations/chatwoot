<script setup>
import { computed, nextTick, onBeforeUnmount, onMounted, ref } from 'vue';
import ContactPanel from 'dashboard/routes/dashboard/conversation/ContactPanel.vue';
import { useUISettings } from 'dashboard/composables/useUISettings';
import { useEventListener, useWindowSize } from '@vueuse/core';
import { vOnClickOutside } from '@vueuse/components';

defineProps({
  currentChat: {
    required: true,
    type: Object,
  },
});

const { uiSettings, updateUISettings } = useUISettings();
const { width: windowWidth } = useWindowSize();
const contactPanel = ref(null);
let returnFocusTarget = null;
let restoreFocusFromBody = false;
// Keep the reply workspace usable beside the native nav and conversation list.
const CONTACT_PANEL_INLINE_BREAKPOINT = 1280; // Tailwind xl

const activeTab = computed(() => {
  const { is_contact_sidebar_open: isContactSidebarOpen } = uiSettings.value;

  if (isContactSidebarOpen) {
    return 0;
  }
  return null;
});

const isSmallScreen = computed(
  () => windowWidth.value < CONTACT_PANEL_INLINE_BREAKPOINT
);

const closeContactPanel = () => {
  if (isSmallScreen.value && uiSettings.value?.is_contact_sidebar_open) {
    updateUISettings({
      is_contact_sidebar_open: false,
      is_copilot_panel_open: false,
    });
  }
};

const onPanelEscape = event => {
  if (
    event.key !== 'Escape' ||
    event.defaultPrevented ||
    event.isComposing ||
    !isSmallScreen.value ||
    !contactPanel.value?.getClientRects().length
  ) {
    return;
  }
  // Native dropdowns close on keyup; teleported popovers also handle Escape
  // on document. Let the open child finish before closing its inspector.
  const childOverlaySelector =
    'dialog.ProseMirror-prompt-backdrop, [data-popover-content], [data-popover-backdrop], .modal-container';
  if (
    event.target?.closest?.(`${childOverlaySelector}, .dropdown-wrap`) ||
    [
      ...contactPanel.value.querySelectorAll(
        '.dropdown-wrap, .label-wrap > .absolute, .fixed.z-50'
      ),
      ...document.querySelectorAll(childOverlaySelector),
    ].some(element => element.getClientRects().length)
  ) {
    return;
  }
  event.preventDefault();
  event.stopPropagation();
  // A child editor may have removed its focused input on the previous Escape.
  restoreFocusFromBody = document.activeElement === document.body;
  closeContactPanel();
};

// The parent mounts this inspector when it opens. Keep the actual keyboard
// origin, including the reply editor when opened with its shortcut.
onMounted(() => {
  returnFocusTarget = document.activeElement;
  nextTick(() => {
    const panel = contactPanel.value;
    if (!isSmallScreen.value || !panel?.getClientRects().length) return;
    (panel.querySelector('[data-sidebar-close]') || panel).focus({
      preventScroll: true,
    });
  });
});

onBeforeUnmount(() => {
  const panel = contactPanel.value;
  const target = returnFocusTarget;
  // An outside click already chose a new input or navigation target.
  if (
    !panel?.contains(document.activeElement) &&
    !(restoreFocusFromBody && document.activeElement === document.body)
  ) {
    return;
  }
  nextTick(() => {
    if (target?.isConnected) target.focus({ preventScroll: true });
  });
});

useEventListener(document, 'keydown', onPanelEscape);
</script>

<template>
  <div
    ref="contactPanel"
    data-toybaco-contact-panel
    tabindex="-1"
    :role="isSmallScreen ? 'dialog' : 'complementary'"
    :aria-label="$t('CONVERSATION.SIDEBAR.CONTACT')"
    v-on-click-outside="[
      () => closeContactPanel(),
      {
        ignore: [
          'dialog.ProseMirror-prompt-backdrop',
          '[data-popover-content]',
          '[data-popover-backdrop]',
        ],
      },
    ]"
    class="bg-n-surface-2 h-full overflow-hidden flex flex-col fixed top-0 z-40 w-full max-w-sm transition-transform duration-300 ease-in-out ltr:right-0 rtl:left-0 xl:static md:w-[320px] md:min-w-[320px] ltr:border-l rtl:border-r border-n-weak 2xl:min-w-[360px] 2xl:w-[360px] shadow-lg xl:shadow-none"
    :class="[
      {
        'md:flex': activeTab === 0,
        'md:hidden': activeTab !== 0,
      },
    ]"
  >
    <div class="flex flex-1 overflow-auto">
      <ContactPanel
        v-show="activeTab === 0"
        :conversation-id="currentChat.id"
        :inbox-id="currentChat.inbox_id"
      />
    </div>
  </div>
</template>
