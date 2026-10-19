import { defineConfig } from 'vite';
import ruby from 'vite-plugin-ruby';
import vue from '@vitejs/plugin-vue';
import { aliases, vueOptions } from './vite.shared';
import yaml from '@rollup/plugin-yaml';

export default defineConfig({
  plugins: [ruby(), vue(vueOptions), yaml()],
  // Vue I18n 9.14.5: interpret message ASTs instead of new Function(). Keep
  // the message parser so API-delivered and tenant-local messages still work.
  define: {
    __INTLIFY_JIT_COMPILATION__: true,
    __INTLIFY_DROP_MESSAGE_COMPILER__: false,
    // @chatwoot/utils 0.0.57 embeds an older regenerator runtime whose
    // strict-mode global assignment falls back to Function(). Register the
    // same runtime on the real global object without compiling a string.
    // Do this in the application build, never by seeding the test VM.
    regeneratorRuntime: 'globalThis.regeneratorRuntime',
  },
  css: {
    preprocessorOptions: {
      scss: {
        api: 'modern-compiler',
      },
    },
  },
  // All production roots have render functions / precompiled SFCs. The portal
  // roots are explicit h() render functions too; no DOM-template compiler.
  resolve: { alias: { ...aliases, vue: 'vue/dist/vue.runtime.esm-bundler.js' } },
});
