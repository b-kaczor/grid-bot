import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  build: {
    assetsDir: 'vite-assets',
  },
  server: {
    proxy: {
      '/api': 'http://localhost:4000',
      '/cable': {
        target: 'ws://localhost:4000',
        ws: true,
      },
    },
  },
})
