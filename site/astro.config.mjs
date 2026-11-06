// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
  site: 'https://kovalov.in',
  integrations: [sitemap()],
  build: {
    // Strict CSP (`style-src 'self'`) forbids inline <style>; ship CSS as files.
    inlineStylesheets: 'never',
  },
  vite: {
    plugins: [tailwindcss()],
    build: {
      // Same reason for scripts: never inline small bundles into HTML.
      assetsInlineLimit: 0,
    },
  },
});
