// Runs the real IndexedDB outbox (src/lib/crew/outbox-idb.ts) in Chromium: photos survive a round trip and a reload,
// are kept per person, and removing one leaves the rest. Types are stripped by Node itself, so no bundler is needed.
//   node scripts/verify-crew-outbox-idb.mjs http://127.0.0.1:3100
import { readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { stripTypeScriptTypes } from 'node:module'
const { chromium } = createRequire(import.meta.url)('playwright')

const base = process.argv[2] ?? 'http://127.0.0.1:3100'
const source = stripTypeScriptTypes(readFileSync(new URL('../src/lib/crew/outbox-idb.ts', import.meta.url), 'utf8'), { mode: 'strip' }).replace('export const idbOutbox', 'window.idbOutbox')

let failed = 0
const check = (ok, what, detail = '') => {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${what}${ok || !detail ? '' : ` (${detail})`}`)
  if (!ok) failed += 1
}

const browser = await chromium.launch()
const context = await browser.newContext()
const page = await context.newPage()
await page.goto(`${base}/crew-offline.html`)
await page.evaluate(() => indexedDB.deleteDatabase('duly-crew'))
await page.addScriptTag({ content: source })

const entry = (id, userId, n) => ({
  id, userId, jobId: 'job-1', areaId: `area-${n}`, kind: 'photo_after', path: `job-1/area-${n}/${n}.jpg`, mime: 'image/jpeg',
  blob: new Blob([new Uint8Array(200_000).fill(n)], { type: 'image/jpeg' }), lat: 51.9, lng: 0.9,
  takenAt: `2026-11-07T10:0${n}:00.000Z`, createdAt: `2026-11-07T10:0${n}:30.000Z`, attempts: 0, status: 'waiting', lastError: null,
})

const first = await page.evaluate(async (mk) => {
  const make = (id, userId, n) => ({ ...JSON.parse(mk), id, userId, areaId: `area-${n}`, path: `job-1/area-${n}/${n}.jpg`, blob: new Blob([new Uint8Array(200000).fill(n)], { type: 'image/jpeg' }) })
  await window.idbOutbox.put(make('a', 'alice', 1))
  await window.idbOutbox.put(make('b', 'alice', 2))
  await window.idbOutbox.put(make('c', 'bob', 3))
  const alice = await window.idbOutbox.list('alice')
  const bob = await window.idbOutbox.list('bob')
  const nobody = await window.idbOutbox.list('carol')
  const photo = alice.find((e) => e.id === 'a')
  const bytes = new Uint8Array(await photo.blob.arrayBuffer())
  return {
    alice: alice.map((e) => e.id).sort(), bob: bob.map((e) => e.id), nobody: nobody.length,
    isBlob: photo.blob instanceof Blob, size: photo.blob.size, type: photo.blob.type, first: bytes[0], last: bytes[bytes.length - 1],
    meta: { takenAt: photo.takenAt, lat: photo.lat, lng: photo.lng, path: photo.path, status: photo.status },
  }
}, JSON.stringify({ ...entry('x', 'x', 1), blob: undefined }))
check(JSON.stringify(first.alice) === '["a","b"]' && JSON.stringify(first.bob) === '["c"]' && first.nobody === 0, 'entries are listed per person', JSON.stringify([first.alice, first.bob, first.nobody]))
check(first.isBlob && first.size === 200000 && first.type === 'image/jpeg' && first.first === 1 && first.last === 1, 'a photo comes back byte for byte', JSON.stringify([first.size, first.type]))
check(first.meta.takenAt === '2026-11-07T10:01:00.000Z' && first.meta.lat === 51.9 && first.meta.lng === 0.9 && first.meta.path === 'job-1/area-1/1.jpg' && first.meta.status === 'waiting', 'when, where and the stored path come back unchanged')

// It survives closing and reopening the page, which is the point.
await page.reload()
await page.addScriptTag({ content: source })
const after = await page.evaluate(async () => (await window.idbOutbox.list('alice')).map((e) => e.id).sort())
check(JSON.stringify(after) === '["a","b"]', 'photos are still there after the page is reloaded', JSON.stringify(after))

// Updating replaces, removing removes only that one.
const edited = await page.evaluate(async () => {
  const [a] = (await window.idbOutbox.list('alice')).filter((e) => e.id === 'a')
  await window.idbOutbox.put({ ...a, status: 'failed', attempts: 2, lastError: 'refused' })
  const rows = await window.idbOutbox.list('alice')
  const row = rows.find((e) => e.id === 'a')
  await window.idbOutbox.remove('b')
  const left = (await window.idbOutbox.list('alice')).map((e) => e.id)
  await window.idbOutbox.remove('does-not-exist')
  return { count: rows.length, status: row.status, attempts: row.attempts, lastError: row.lastError, left, bob: (await window.idbOutbox.list('bob')).length }
})
check(edited.count === 2 && edited.status === 'failed' && edited.attempts === 2 && edited.lastError === 'refused', 'updating an entry replaces it rather than adding another', JSON.stringify(edited))
check(JSON.stringify(edited.left) === '["a"]' && edited.bob === 1, 'removing one entry leaves the others, including other people\'s')

// Several at once do not trip over each other.
const many = await page.evaluate(async () => {
  await Promise.all(Array.from({ length: 12 }, (_, i) => window.idbOutbox.put({ id: `m${i}`, userId: 'dave', createdAt: `2026-11-07T10:00:${String(i).padStart(2, '0')}Z`, blob: new Blob([String(i)]) })))
  return (await window.idbOutbox.list('dave')).length
})
check(many === 12, 'twelve photos saved at once are all kept', String(many))

await browser.close()
console.log(failed ? `\n${failed} check(s) failed` : '\nAll checks passed')
process.exit(failed ? 1 : 0)
