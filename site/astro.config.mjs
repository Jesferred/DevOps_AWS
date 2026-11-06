// @ts-check
import { defineConfig } from 'astro/config';
import mdx from '@astrojs/mdx';
import sitemap from '@astrojs/sitemap';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
  site: 'https://kovalov.in',
  integrations: [mdx(), sitemap()],
  markdown: {
    // Prism emits CSS classes; Shiki emits inline style="" that the CSP blocks.
    syntaxHighlight: 'prism',
  },
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
