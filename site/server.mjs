// Serveur statique minimal pour le site vitrine — zéro dépendance.
// Heroku impose le port d'écoute via $PORT ; en local : PORT=8080.
import { createServer } from 'node:http'
import { readFile, stat } from 'node:fs/promises'
import { extname, join, normalize } from 'node:path'

const ROOT = new URL('./dist', import.meta.url).pathname
const PORT = Number(process.env.PORT) || 8080

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.webp': 'image/webp',
  '.ico': 'image/x-icon',
  '.json': 'application/json',
  '.txt': 'text/plain; charset=utf-8',
  '.woff2': 'font/woff2',
}

createServer(async (req, res) => {
  try {
    // normalize + préfixe ROOT : impossible de sortir du dossier dist.
    const urlPath = decodeURIComponent(new URL(req.url, 'http://x').pathname)
    let filePath = normalize(join(ROOT, urlPath))
    if (!filePath.startsWith(ROOT)) {
      res.writeHead(403).end()
      return
    }
    if ((await stat(filePath).catch(() => null))?.isDirectory()) {
      filePath = join(filePath, 'index.html')
    }
    let body
    try {
      body = await readFile(filePath)
    } catch {
      // Page inconnue → index.html (le site est une page unique).
      filePath = join(ROOT, 'index.html')
      body = await readFile(filePath)
    }
    const type = TYPES[extname(filePath)] ?? 'application/octet-stream'
    // Les assets Vite sont fingerprintés : cache long ; l'index jamais.
    const cache = filePath.includes('/assets/')
      ? 'public, max-age=31536000, immutable'
      : 'no-cache'
    res.writeHead(200, { 'Content-Type': type, 'Cache-Control': cache })
    res.end(body)
  } catch {
    res.writeHead(500).end()
  }
}).listen(PORT, '0.0.0.0', () => {
  console.log(`Optyx site sur http://0.0.0.0:${PORT}`)
})
