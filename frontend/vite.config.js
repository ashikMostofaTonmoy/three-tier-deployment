import { execSync } from 'node:child_process';
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// A short, human-readable stamp for THIS build. CI passes BUILD_ID in; locally we
// fall back to the current git short SHA (or "dev" if git is unavailable) plus a
// UTC timestamp. The app shows this on screen, so every deploy looks different and
// you can prove a redeploy actually happened.
function buildId() {
  if (process.env.BUILD_ID) return process.env.BUILD_ID;
  let sha = 'dev';
  try {
    sha = execSync('git rev-parse --short HEAD').toString().trim();
  } catch {
    // no git here — that's fine
  }
  const stamp = new Date().toISOString().replace(/\.\d+Z$/, 'Z');
  return `${sha} @ ${stamp}`;
}

// The frontend NEVER calls the weather API directly. It always calls a relative
// URL that starts with /api. In production, Nginx forwards /api to Open-Meteo.
// Here in local dev there is no Nginx, so Vite's dev server does the same job:
// anything starting with /api is forwarded to https://api.open-meteo.com and the
// leading /api is stripped. This keeps the app's code identical in every setup.
const apiProxy = {
  '/api': {
    target: 'https://api.open-meteo.com',
    changeOrigin: true,
    rewrite: (path) => path.replace(/^\/api/, ''),
  },
};

export default defineConfig({
  plugins: [react()],
  define: {
    __BUILD_ID__: JSON.stringify(buildId()),
  },
  server: { port: 5173, proxy: apiProxy },
  preview: { port: 4173, proxy: apiProxy },
});
