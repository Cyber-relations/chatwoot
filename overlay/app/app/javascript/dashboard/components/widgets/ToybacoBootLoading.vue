<template>
  <div class="toybaco-boot-loading">
    <span class="toybaco-boot-ring" role="status" aria-label="トイバコを読み込んでいます" />
  </div>
</template>

<style scoped>
.toybaco-boot-loading {
  display: grid;
  place-items: center;
  width: 100%;
  min-height: 100vh;
  min-height: 100dvh;
  background: var(--toybaco-surface, #faf7f2);
}
.toybaco-boot-ring {
  display: block;
  width: 28px;
  height: 28px;
  box-sizing: border-box;
  border: 3px solid var(--toybaco-hairline, #dce2e8);
  border-top-color: var(--toybaco-muted, #66758a);
  border-radius: 50%;
  animation: toybaco-boot-spin 1s linear infinite;
}
@keyframes toybaco-boot-spin { to { transform: rotate(360deg); } }
@media (prefers-reduced-motion: reduce) {
  .toybaco-boot-ring { animation: none; }
}
</style>
