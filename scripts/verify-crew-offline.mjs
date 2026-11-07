// Runs the built app in a real browser and checks what the Crew service worker does.
//   pnpm build && PORT=3100 node .output/server/index.mjs &
//   node scripts/verify-crew-offline.mjs http://127.0.0.1:3100
// Needs Playwright's Chromium (a developer tool, not an app dependency). Exits non-zero if anything is wrong.
import { createRequire } from 'node:module'
const { chromium } = createRequire(import.meta.url)('playwright')

const base = process.argv[2] ?? 'http://127.0.0.1:3100'
let failed = 0
const check = (ok, what, detail = '') => {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${what}${ok || !detail ? '' : ` (${detail})`}`)
  if (!ok) failed += 1
}

const browser = await chromium.launch()
const context = await browser.newContext({ viewport: { width: 390, height: 844 } })
const page = await context.newPage()
const text = () => page.locator('body').innerText()

// 1. It registers on the Crew pages and takes control.
await page.goto(`${base}/crew`, { waitUntil: 'networkidle' })
const ready = await page.evaluate(async () => {
  const reg = await Promise.race([navigator.serviceWorker.ready, new Promise((r) => setTimeout(() => r(null), 8000))])
  return reg ? { scope: new URL(reg.scope).pathname, state: reg.active?.state } : null
})
check(ready?.scope === '/crew' && ready.state === 'activated', 'the worker registers with scope /crew and activates', JSON.stringify(ready))
await page.reload({ waitUntil: 'networkidle' })
check(await page.evaluate(() => Boolean(navigator.serviceWorker.controller)), 'it controls the Crew page after a reload')

// 2. What it has stored: static things only.
const stored = await page.evaluate(async () => {
  const out = {}
  for (const name of await caches.keys()) out[name] = (await (await caches.open(name)).keys()).map((r) => new URL(r.url).pathname + (new URL(r.url).host.startsWith('127') ? '' : ' @' + new URL(r.url).host))
  return out
})
const all = Object.values(stored).flat()
check(Object.keys(stored).every((n) => n.startsWith('crew-')), 'every cache it makes is its own (crew-…)', Object.keys(stored).join(','))
check(['/crew-offline.html', '/crew.webmanifest', '/icon.svg', '/icons/icon-192.png', '/icons/icon-512.png'].every((p) => stored['crew-shell-v1']?.includes(p)), 'the offline page, manifest and icons are kept')
check(all.some((p) => p.startsWith('/assets/')), 'the app\'s hashed build files are kept', `${all.filter((p) => p.startsWith('/assets/')).length} files`)
check(stored['crew-pages-v1']?.includes('/crew'), 'the last good copy of the Crew page is kept')
const expected = (p) =>
  p.startsWith('/assets/') || // the app's own hashed build files (this includes its bundled Supabase library, which is just code)
  ['/crew', '/crew-offline.html', '/crew.webmanifest', '/icon.svg', '/icons/icon-192.png', '/icons/icon-512.png'].includes(p) ||
  p.endsWith('@fonts.googleapis.com') || p.endsWith('@fonts.gstatic.com') // web fonts
const unexpected = all.filter((p) => !expected(p))
check(unexpected.length === 0, 'everything stored is a static file of the app, the Crew page or a web font: no data, no API responses, nothing from other sites', unexpected.join(', '))
check(!all.some((p) => /\.(jpe?g|png|webp|heic)$/i.test(p) && !p.startsWith('/icons/')), 'no photos are stored')

// 3. It never interferes with other sites' requests (Supabase, postcode lookup, maps): they reach the network.
let reached = 0
await context.route('https://data.example.test/**', (route) => {
  reached += 1
  route.fulfill({ status: 200, contentType: 'application/json', body: '{"live":true}' })
})
const live = await page.evaluate(async () => (await (await fetch('https://data.example.test/rest/v1/jobs')).json()).live)
check(reached === 1 && live === true, 'a request to another site goes to the network, not the worker', `reached=${reached}`)
const afterCall = await page.evaluate(async () => (await Promise.all((await caches.keys()).map(async (n) => (await (await caches.open(n)).keys()).length))).reduce((a, b) => a + b, 0))
check(afterCall === all.length, 'and is not stored', `${all.length} -> ${afterCall}`)
const method = await page.evaluate(async () => {
  try {
    await fetch('/crew-offline.html', { method: 'POST', body: 'x' })
  } catch {}
  return (await caches.open('crew-shell-v1').then((c) => c.keys())).length
})
check(method === stored['crew-shell-v1'].length, 'a POST is never answered from, or stored in, the cache')

// 4. Offline: the Crew app still opens, an unseen page gets the plain offline page, other areas are left alone.
await context.setOffline(true)
await page.goto(`${base}/crew`, { waitUntil: 'domcontentloaded' })
await page.waitForTimeout(1500)
const offlineHome = await text()
check(/Duly/.test(offlineHome) && !/You're offline\s*\n\s*This page isn't saved/.test(offlineHome), 'offline, the Crew page opens from the saved copy', offlineHome.slice(0, 60).replace(/\n/g, ' '))
check(await page.evaluate(() => document.querySelectorAll('input, button').length > 0), 'and the app itself runs (it hydrated from saved files)')
await page.goto(`${base}/crew/11111111-1111-4111-8111-111111111111`, { waitUntil: 'domcontentloaded' })
const unseen = await text()
check(/You're offline/.test(unseen) && /Photos still work/.test(unseen), 'offline, a page it has never seen gets the plain offline page')
let outsideFailed = false
try {
  await page.goto(`${base}/`, { waitUntil: 'domcontentloaded', timeout: 5000 })
} catch {
  outsideFailed = true
}
check(outsideFailed, 'offline, the rest of Duly is left alone (the worker does not answer for it)')
await context.setOffline(false)

// 5. Online again it fetches fresh, and the offline page reloads itself when the connection returns.
await page.goto(`${base}/crew`, { waitUntil: 'networkidle' })
check(!/You're offline/.test(await text()), 'back online, the live Crew page loads')

// 6. Signing out wipes what it stored.
const wiped = await page.evaluate(async () => {
  const reg = await navigator.serviceWorker.getRegistration('/crew')
  await new Promise((resolve) => {
    const channel = new MessageChannel()
    channel.port1.onmessage = resolve
    reg.active.postMessage({ type: 'CLEAR_CACHES' }, [channel.port2])
  })
  const out = {}
  for (const name of await caches.keys()) out[name] = (await (await caches.open(name)).keys()).length
  return out
})
check(!wiped['crew-assets-v1'] && !wiped['crew-pages-v1'], 'clearing empties the saved build files and pages', JSON.stringify(wiped))
check(wiped['crew-shell-v1'] >= 5, 'and puts the offline page back so it still works', JSON.stringify(wiped))

// 7. Installable, with real icons.
const cdp = await context.newCDPSession(page)
await cdp.send('Page.enable')
const { installabilityErrors } = await cdp.send('Page.getInstallabilityErrors')
check(installabilityErrors.length === 0, 'Chrome finds nothing stopping it being installed', JSON.stringify(installabilityErrors))
const manifest = await cdp.send('Page.getAppManifest')
check(!(manifest.errors ?? []).length, 'the manifest has no errors', JSON.stringify(manifest.errors))
const parsed = JSON.parse(manifest.data || '{}')
check(parsed.display === 'standalone' && parsed.start_url === '/crew' && parsed.scope === '/crew' && parsed.id === '/crew', 'it opens as its own app at /crew')
for (const icon of parsed.icons ?? []) {
  const res = await page.request.get(new URL(icon.src, base).toString())
  check(res.ok() && (res.headers()['content-type'] ?? '').includes(icon.type), `icon ${icon.src} (${icon.sizes}, ${icon.purpose}) is served`, `${res.status()} ${res.headers()['content-type']}`)
}
check((parsed.icons ?? []).some((i) => i.purpose === 'maskable' && i.sizes === '512x512'), 'there is a maskable icon')
const touch = await page.evaluate(() => document.querySelector('link[rel="apple-touch-icon"]')?.getAttribute('href'))
check(touch === '/icons/apple-touch-icon.png', 'iPhone gets its home-screen icon', String(touch))

await browser.close()
console.log(failed ? `\n${failed} check(s) failed` : '\nAll checks passed')
process.exit(failed ? 1 : 0)
