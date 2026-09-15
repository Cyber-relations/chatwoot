<script setup>
import { ref } from 'vue';
import { useToggle } from '@vueuse/core';
import { vOnClickOutside } from '@vueuse/components';
import DropdownFloating from './DropdownFloating.vue';
import { provideDropdownContext, useDropdownTeleport } from './provider.js';

const props = defineProps({
  closeOnEscape: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['close']);
const [isOpen, toggle] = useToggle(false);

const teleport = useDropdownTeleport();
const containerRef = ref(null);

// A getter, not a computed: consumers swap the trigger element as their state changes — a multi
// select trades its placeholder for a chips button once something is picked.
const getTrigger = () => containerRef.value?.firstElementChild ?? null;

const closeMenu = () => {
  if (isOpen.value) {
    emit('close');
    toggle(false);
  }
};

const onKeydown = event => {
  if (
    !props.closeOnEscape ||
    !isOpen.value ||
    event.key !== 'Escape' ||
    event.isComposing ||
    event.keyCode === 229 ||
    event.defaultPrevented
  ) {
    return;
  }

  const trigger = getTrigger();
  event.preventDefault();
  event.stopPropagation();
  closeMenu();

  if (
    !trigger?.isConnected ||
    trigger.matches(':disabled, [aria-disabled="true"]') ||
    trigger.closest('[inert], [aria-hidden="true"], [hidden]') ||
    !trigger.getClientRects().length
  ) {
    return;
  }
  const style = window.getComputedStyle(trigger);
  if (
    style.display === 'none' ||
    ['hidden', 'collapse'].includes(style.visibility)
  ) {
    return;
  }
  trigger.focus();
};

// A teleported menu sits outside the container, so clicks inside it read as clicks outside.
const clickOutsideHandler = [closeMenu, { ignore: ['[data-dropdown-menu]'] }];

provideDropdownContext({
  isOpen,
  toggle,
  closeMenu,
});
</script>

<template>
  <div
    ref="containerRef"
    v-on-click-outside="clickOutsideHandler"
    class="relative space-y-2"
    @keydown="onKeydown"
  >
    <slot name="trigger" :is-open :toggle="() => toggle()" />
    <template v-if="isOpen">
      <DropdownFloating v-if="teleport" :trigger="getTrigger">
        <slot />
      </DropdownFloating>
      <div v-else class="absolute">
        <slot />
      </div>
    </template>
  </div>
</template>
