<script setup>
defineProps({
  omissions: { type: Array, default: () => [] },
});
</script>

<template>
  <ul v-if="omissions.length" class="space-y-1 text-sm text-n-slate-11">
    <li v-for="(omission, index) in omissions" :key="index" class="break-all">
      保存しなかった添付ファイル: {{ omission.filename }}
    </li>
  </ul>
</template>
