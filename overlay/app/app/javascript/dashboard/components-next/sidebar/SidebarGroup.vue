<script setup>
import { computed, onMounted, onUnmounted, watch, nextTick, ref } from 'vue';
import { useSidebarContext, usePopoverState } from './provider';
import { useRoute, useRouter } from 'vue-router';
import Policy from 'dashboard/components/policy.vue';
import Icon from 'next/icon/Icon.vue';
import SidebarGroupHeader from './SidebarGroupHeader.vue';
import SidebarGroupLeaf from './SidebarGroupLeaf.vue';
import SidebarSubGroup from './SidebarSubGroup.vue';
import SidebarGroupEmptyLeaf from './SidebarGroupEmptyLeaf.vue';
import SidebarCollapsedPopover from './SidebarCollapsedPopover.vue';

const props = defineProps({
  name: { type: String, required: true },
  label: { type: String, required: true },
  icon: { type: [String, Object, Function], default: null },
  to: { type: Object, default: null },
  activeOn: { type: Array, default: () => [] },
  children: { type: Array, default: undefined },
  getterKeys: { type: Object, default: () => ({}) },
});

const {
  expandedItem,
  setExpandedItem,
  resolvePath,
  resolvePermissions,
  resolveFeatureFlag,
  isAllowed,
  isCollapsed,
  isResizing,
} = useSidebarContext();

const {
  activePopover,
  setActivePopover,
  closeActivePopover,
  scheduleClose,
  cancelClose,
} = usePopoverState();

const navigableChildren = computed(() => {
  return props.children?.flatMap(child => child.children || child) || [];
});

const route = useRoute();
const router = useRouter();
const isExpanded = computed(() => expandedItem.value === props.name);
const isExpandable = computed(() => props.children);
const hasChildren = computed(
  () => Array.isArray(props.children) && props.children.length > 0
);

// Use shared popover state - only one popover can be open at a time
const isPopoverOpen = computed(() => activePopover.value === props.name);
const triggerRef = ref(null);
const popoverId = computed(
  () => `toybaco-sidebar-popover-${encodeURIComponent(props.name)}`
);
const childrenId = computed(
  () => `toybaco-sidebar-children-${encodeURIComponent(props.name)}`
);
const focusRequest = ref(0);
const popoverContainsFocus = () =>
  document.getElementById(popoverId.value)?.contains(document.activeElement);
const triggerRect = ref({ top: 0, left: 0, bottom: 0, right: 0 });
// The sort dropdown teleports outside the popover; keep the popover open while
// it is showing so moving the cursor onto it does not close everything.
const isSortMenuOpen = ref(false);

const openPopover = (withKeyboardFocus = false) => {
  if (triggerRef.value) {
    const rect = triggerRef.value.getBoundingClientRect();
    triggerRect.value = {
      top: rect.top,
      left: rect.left,
      bottom: rect.bottom,
      right: rect.right,
    };
  }
  focusRequest.value = withKeyboardFocus ? focusRequest.value + 1 : 0;
  setActivePopover(props.name);
};

const closePopover = () => {
  focusRequest.value = 0;
  if (activePopover.value === props.name) {
    closeActivePopover();
  }
};

const handleMouseEnter = () => {
  if (!hasChildren.value || isResizing.value) return;
  cancelClose();
  openPopover();
};

const handleMouseLeave = () => {
  if (!hasChildren.value || isSortMenuOpen.value || popoverContainsFocus())
    return;
  scheduleClose(200);
};

const handlePopoverMouseEnter = () => {
  cancelClose();
};

const handlePopoverMouseLeave = () => {
  if (isSortMenuOpen.value || popoverContainsFocus()) return;
  scheduleClose(100);
};

const handlePopoverFocusout = event => {
  const popover = document.getElementById(popoverId.value);
  if (isSortMenuOpen.value || popover?.contains(event.relatedTarget)) return;
  closePopover();
};

const closePopoverAndFocusTrigger = async () => {
  cancelClose();
  closePopover();
  await nextTick();
  if (isCollapsed.value) triggerRef.value?.focus();
};

const handleCollapsedKeydown = event => {
  if (
    event.defaultPrevented ||
    event.isComposing ||
    event.keyCode === 229 ||
    event.altKey ||
    event.ctrlKey ||
    event.metaKey ||
    event.shiftKey ||
    !hasAccessibleChildren.value ||
    isResizing.value
  )
    return;
  if (event.key === 'ArrowRight' || event.key === 'ArrowDown') {
    event.preventDefault();
    event.stopPropagation();
    cancelClose();
    openPopover(true);
  } else if (event.key === 'Escape' && isPopoverOpen.value) {
    event.preventDefault();
    event.stopPropagation();
    closePopoverAndFocusTrigger();
  }
};

const handleSortToggle = isOpen => {
  isSortMenuOpen.value = isOpen;
  cancelClose();
};

// Close popover when mouse leaves the window
const handleWindowBlur = () => {
  closeActivePopover();
};

const hasAccessibleSubChildren = child => {
  return child.children?.some(
    subChild => subChild.to && isAllowed(subChild.to)
  );
};

const visibleChildren = computed(() => {
  if (!hasChildren.value) return [];

  return props.children.filter(child => {
    if (child.children) return hasAccessibleSubChildren(child);

    return child.to && isAllowed(child.to);
  });
});

const accessibleItems = computed(() => {
  if (!hasChildren.value) return [];

  return visibleChildren.value
    .flatMap(child => child.children || child)
    .filter(child => child.to && isAllowed(child.to));
});

const hasAccessibleChildren = computed(() => {
  return visibleChildren.value.length > 0;
});

// The assistant must not infer access from submenu links: those leaves are
// unmounted in the collapsed sidebar. Keep this bridge on the permitted group.
const inboxSettingsItem = computed(() => {
  const accountPath = route.path.match(/^\/app\/accounts\/[1-9]\d*(?=\/|$)/)?.[0];
  if (!accountPath) return null;
  return accessibleItems.value.find(
    item => resolvePath(item.to) === `${accountPath}/settings/inboxes/list`
  );
});
const inboxSettingsPath = computed(() =>
  inboxSettingsItem.value ? resolvePath(inboxSettingsItem.value.to) : undefined
);
const openInboxSettings = event => {
  const item = inboxSettingsItem.value;
  if (!item || event.detail?.path !== inboxSettingsPath.value ||
      typeof event.detail?.proceed !== 'function') return;
  event.detail.proceed();
  router.push(item.to);
};

const isLastVisibleChild = child => {
  const lastChild = visibleChildren.value[visibleChildren.value.length - 1];
  return lastChild === child;
};

const isActive = computed(() => {
  if (props.to) {
    if (route.path === resolvePath(props.to)) return true;

    return props.activeOn.includes(route.name);
  }

  return false;
});

// We could use the RouterLink isActive too, but our routes are not always
// nested correctly, so we need to check the active state ourselves
// TODO: Audit the routes and fix the nesting and remove this
const activeChild = computed(() => {
  const pathSame = navigableChildren.value.find(
    child => child.to && route.path === resolvePath(child.to)
  );
  if (pathSame) return pathSame;

  // Rank the activeOn Prop higher than the path match
  // There will be cases where the path name is the same but the params are different
  // So we need to rank them based on the params
  // For example, contacts segment list in the sidebar effectively has the same name
  // But the params are different
  const activeOnPages = navigableChildren.value.filter(child =>
    child.activeOn?.includes(route.name)
  );

  if (activeOnPages.length > 0) {
    const rankedPage = activeOnPages.find(child => {
      return Object.keys(child.to.params)
        .map(key => {
          return String(child.to.params[key]) === String(route.params[key]);
        })
        .every(match => match);
    });

    // If there is no ranked page, return the first activeOn page anyway
    // Since this takes higher precedence over the path match
    // This is not perfect, ideally we should rank each route based on all the techniques
    // and then return the highest ranked one
    // But this is good enough for now
    return rankedPage ?? activeOnPages[0];
  }

  return navigableChildren.value.find(child => {
    if (!child.to) return false;
    const childPath = resolvePath(child.to);
    return route.path === childPath || route.path.startsWith(`${childPath}/`);
  });
});

const hasActiveChild = computed(() => {
  return activeChild.value !== undefined;
});

const handleCollapsedClick = () => {
  if (hasChildren.value && hasAccessibleChildren.value) {
    const firstItem = accessibleItems.value[0];
    router.push(firstItem.to);
  }
};

const toggleTrigger = () => {
  const firstItem = hasAccessibleChildren.value &&
    !isExpanded.value && !hasActiveChild.value
    ? accessibleItems.value[0] : null;
  // Capture intent before route watchers can expand this group during navigation.
  const nextExpanded = !isExpanded.value;
  const applyExpansion = () => {
    if (isExpanded.value !== nextExpanded) setExpandedItem(props.name);
  };
  if (hasChildren.value && !props.to) {
    const request = {
      handled: false,
      navigates: Boolean(firstItem),
      preserveExpanded: isExpanded.value && hasActiveChild.value,
      proceed: () => {
        if (!firstItem) { applyExpansion(); return; }
        router.push(firstItem.to).then(failure => {
          if (!failure && hasActiveChild.value) applyExpansion();
        });
      },
    };
    window.dispatchEvent(new CustomEvent('toybaco:posting-group-toggle', {
      detail: request,
    }));
    if (request.handled) return;
  }
  // Without a posting panel, retain the native immediate toggle behavior.
  if (firstItem) router.push(firstItem.to);
  setExpandedItem(props.name);
};

onMounted(async () => {
  await nextTick();
  if (hasActiveChild.value && !isExpanded.value) {
    setExpandedItem(props.name);
  }
  window.addEventListener('blur', handleWindowBlur);
  document.addEventListener('mouseleave', handleWindowBlur);
});

onUnmounted(() => {
  window.removeEventListener('blur', handleWindowBlur);
  document.removeEventListener('mouseleave', handleWindowBlur);
});

watch(
  [() => route.path, hasActiveChild],
  () => {
    if (hasActiveChild.value && !isExpanded.value) {
      setExpandedItem(props.name);
    }
  }
);
</script>

<!-- eslint-disable-next-line vue/no-root-v-if -->
<template>
  <Policy
    v-if="!hasChildren || hasAccessibleChildren"
    :permissions="resolvePermissions(to)"
    :feature-flag="resolveFeatureFlag(to)"
    as="li"
    class="grid gap-1 text-sm cursor-pointer select-none min-w-0"
    :data-toybaco-inbox-settings-path="inboxSettingsPath"
    @toybaco-open-inbox-settings="openInboxSettings"
  >
    <!-- Collapsed State -->
    <template v-if="isCollapsed">
      <div
        class="relative"
        @mouseenter="handleMouseEnter"
        @mouseleave="handleMouseLeave"
      >
        <component
          :is="to && !hasChildren ? 'router-link' : 'button'"
          ref="triggerRef"
          :to="to && !hasChildren ? to : undefined"
          type="button"
          class="flex items-center justify-center size-10 rounded-lg"
          :class="{
            'text-n-slate-12 bg-n-alpha-2': isActive || hasActiveChild,
            'text-n-slate-11 hover:bg-n-alpha-2': !isActive && !hasActiveChild,
          }"
          :title="label"
          :aria-label="label"
          :aria-expanded="hasAccessibleChildren ? isPopoverOpen : undefined"
          :aria-controls="
            hasAccessibleChildren && isPopoverOpen ? popoverId : undefined
          "
          @keydown="handleCollapsedKeydown"
          @click="hasChildren ? handleCollapsedClick() : undefined"
        >
          <Icon v-if="icon" :icon="icon" class="size-4" />
        </component>
        <SidebarCollapsedPopover
          v-if="hasChildren && isPopoverOpen"
          :id="popoverId"
          :focus-request="focusRequest"
          :label="label"
          :children="children"
          :active-child="activeChild"
          :trigger-rect="triggerRect"
          @close="closePopover"
          @escape="closePopoverAndFocusTrigger"
          @focusin="cancelClose"
          @focusout="handlePopoverFocusout"
          @mouseenter="handlePopoverMouseEnter"
          @mouseleave="handlePopoverMouseLeave"
          @sort-toggle="handleSortToggle"
        />
      </div>
    </template>
    <!-- Expanded State -->
    <template v-else>
      <SidebarGroupHeader
        :icon
        :name
        :label
        :to
        :getter-keys="getterKeys"
        :is-active="isActive"
        :has-active-child="hasActiveChild"
        :expandable="hasChildren"
        :is-expanded="isExpanded"
        :aria-expanded="hasChildren ? isExpanded : undefined"
        :data-toybaco-native-expanded="hasChildren ? String(isExpanded) : undefined"
        :aria-controls="hasChildren ? childrenId : undefined"
        @toggle="toggleTrigger"
      />
      <ul
        v-if="hasChildren"
        :id="childrenId"
        v-show="isExpanded"
        class="grid m-0 list-none min-w-0"
      >
        <template v-for="child in visibleChildren" :key="child.name">
          <SidebarSubGroup
            v-if="child.children"
            :name="`${name}:${child.name}`"
            :label="child.label"
            :icon="child.icon"
            :children="child.children"
            :collapsible="child.collapsible"
            :show-tree-line="child.showTreeLine"
            :end-tree-line="child.showTreeLine && isLastVisibleChild(child)"
            :is-expanded="isExpanded"
            :active-child="activeChild"
            :sort-options="child.sortOptions"
            :active-sort="child.activeSort"
            @update-sort="child.onSortChange"
          />
          <SidebarGroupLeaf
            v-else-if="isAllowed(child.to)"
            v-show="isExpanded || activeChild?.name === child.name"
            v-bind="child"
            :active="activeChild?.name === child.name"
          />
        </template>
      </ul>
      <ul v-else-if="isExpandable && isExpanded">
        <SidebarGroupEmptyLeaf />
      </ul>
    </template>
  </Policy>
</template>
