import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// base relative : le site fonctionne servi depuis n'importe quel
// sous-chemin (GitHub Pages, hébergement statique, file://).
export default defineConfig({
  plugins: [react()],
  base: './',
})
