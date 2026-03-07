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
      '/api': 'http://localhost:3000',
      '/cable': {
        target: 'ws://localhost:3000',
        ws: true,
      },
    },
  },
})
