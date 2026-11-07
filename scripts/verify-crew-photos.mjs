// Drives the real Crew job sheet in Chromium against a fake Supabase, to check the photo outbox end to end:
// a photo with a signal, one without, the reconnect, a flaky connection, a refusal, a half-finished send, and that
// check-in / finishing refuse to run offline or while photos are waiting.
//   pnpm build && PORT=3100 node .output/server/index.mjs &
//   node scripts/verify-crew-photos.mjs http://127.0.0.1:3100
import { createRequire } from 'node:module'
const { chromium } = createRequire(import.meta.url)('playwright')

const base = process.argv[2] ?? 'http://127.0.0.1:3100'
const SUPABASE = /^https:\/\/mnlyltdxnvzbttugkmng\.supabase\.co\//
const JOB = '22222222-2222-4222-8222-222222222222'
const USER = '33333333-3333-4333-8333-333333333333'
const GEO = { latitude: 51.8909, longitude: 0.9009 }
let failed = 0
const check = (ok, what, detail = '') => {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${what}${ok || !detail ? '' : ` (${detail})`}`)
  if (!ok) failed += 1
}
const until = async (fn, what, ms = 8000) => {
  const end = Date.now() + ms
  while (Date.now() < end) {
    if (await fn()) return true
    await new Promise((r) => setTimeout(r, 100))
  }
  check(false, `waited for: ${what}`)
  return false
}

// ---------------------------------------------------------------- the fake backend
const state = {
  offline: false,
  jobStatus: 'in_progress',
  evidence: [],
  storage: new Map(),
  results: [],
  calls: { upload: 0, insert: 0, exists: 0, complete: 0, checkIn: 0 },
  uploads: [], inserts: [],
  failNext: { uploadAbort: 0, insertAbort: 0, insertRefuse: 0 },
  failPaths: new Set(),
}
const schedule = [{ name: 'Clinical', areas: [
  { id: 'a1', name: 'Surgery', minutes: 30, standards: [{ id: 's1', text: 'Floor clean' }] },
  { id: 'a2', name: 'Waiting room', minutes: 20, standards: [{ id: 's2', text: 'Seats wiped' }] },
] }]
const seed = () => {
  state.evidence = ['a1', 'a2'].map((a, i) => ({ id: `e${i}`, area_id: a, kind: 'photo_after', storage_path: `${JOB}/${a}/seed.jpg`, within_geofence: true, created_at: '2026-11-07T09:00:00Z' }))
  state.results = ['a1:s1', 'a2:s2'].map((k) => ({ area_id: k.split(':')[0], standard_id: k.split(':')[1], done_by_operative: true, verdict: null }))
}
const CORS = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*', 'access-control-expose-headers': '*' }
const json = (route, status, body) => route.fulfill({ status, headers: { ...CORS, 'content-type': 'application/json' }, body: body === undefined ? '' : JSON.stringify(body) })
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==', 'base64')

async function backend(route) {
  const req = route.request()
  const url = new URL(req.url())
  const path = url.pathname
  if (req.method() === 'OPTIONS') return route.fulfill({ status: 204, headers: CORS })
  if (state.offline || state.failPaths.has(path)) return route.abort('internetdisconnected')
  const one = (req.headers().accept ?? '').includes('vnd.pgrst.object')
  const rows = (arr) => (one ? (arr[0] ? json(route, 200, arr[0]) : json(route, 406, { message: 'no rows' })) : json(route, 200, arr))

  if (path === '/auth/v1/user') return json(route, 200, { id: USER, aud: 'authenticated', email: 'crew@example.test', app_metadata: {}, user_metadata: { has_password: true } })
  if (path === '/rest/v1/memberships') return rows([{ org_id: 'org-1', role: 'operative', org: { id: 'org-1', name: 'Clean-Fit', kind: 'vendor', segment: null } }])
  if (path === '/rest/v1/workers') return rows([])
  if (path === '/rest/v1/job_assignments') return rows([])
  if (path === '/rest/v1/jobs') return rows([{ id: JOB, status: state.jobStatus, scheduled_start: '2026-11-08T18:00:00Z', scheduled_end: '2026-11-08T20:00:00Z', brief_id: 'b1', brief_version: 1,
    site: { name: 'Harbour Dental', address_line1: '1 Quay Street', town: 'Colchester', postcode: 'CO1 1AA', access_notes: 'Key safe' } }])
  if (path === '/rest/v1/brief_versions') return rows([{ schedule, notes: null }])
  if (path === '/rest/v1/area_results') return rows(state.results)
  if (path === '/rest/v1/job_events') return rows([])
  if (path === '/rest/v1/evidence' && req.method() === 'GET') {
    const sp = url.searchParams.get('storage_path')
    if (sp) { state.calls.exists += 1; return rows(state.evidence.filter((e) => `eq.${e.storage_path}` === sp).map((e) => ({ id: e.id }))) }
    return rows(state.evidence)
  }
  if (path === '/rest/v1/evidence' && req.method() === 'POST') {
    state.calls.insert += 1
    const body = JSON.parse(req.postData() ?? '{}')
    state.inserts.push(body)
    if (state.failNext.insertAbort > 0) { state.failNext.insertAbort -= 1; return route.abort('connectionreset') }
    if (state.failNext.insertRefuse > 0) { state.failNext.insertRefuse -= 1; return json(route, 403, { code: '42501', message: 'new row violates row-level security policy for table "evidence"' }) }
    if (state.evidence.some((e) => e.storage_path === body.storage_path)) return json(route, 409, { code: '23505', message: 'duplicate key value violates unique constraint "evidence_storage_path_key"' })
    state.evidence.push({ id: `n${state.evidence.length}`, ...body, within_geofence: true, created_at: new Date().toISOString() })
    return route.fulfill({ status: 201, headers: CORS, body: '' })
  }
  if (path.startsWith('/storage/v1/object/evidence/') && req.method() === 'POST') {
    state.calls.upload += 1
    const file = decodeURIComponent(path.replace('/storage/v1/object/evidence/', ''))
    state.uploads.push(file)
    if (state.failNext.uploadAbort > 0) { state.failNext.uploadAbort -= 1; return route.abort('connectionreset') }
    if (state.storage.has(file)) return json(route, 400, { statusCode: '409', error: 'Duplicate', message: 'The resource already exists' })
    state.storage.set(file, true)
    return json(route, 200, { Key: `evidence/${file}`, Id: 'x' })
  }
  if (path.startsWith('/storage/v1/object/sign/evidence') && req.method() === 'POST') {
    const { paths = [] } = JSON.parse(req.postData() ?? '{}')
    return json(route, 200, paths.map((p) => ({ path: p, signedURL: `/object/sign/evidence/${p}?token=t`, error: null })))
  }
  if (path.startsWith('/storage/v1/object/sign/')) return route.fulfill({ status: 200, headers: { ...CORS, 'content-type': 'image/png' }, body: PNG })
  if (path === '/rest/v1/rpc/complete_job') { state.calls.complete += 1; return json(route, 200, null) }
  if (path === '/rest/v1/rpc/check_in') { state.calls.checkIn += 1; return json(route, 200, { within_geofence: true, late_minutes: 0 }) }
  return json(route, 404, { message: `no stub for ${req.method()} ${path}` })
}

const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
const jwt = `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: USER, role: 'authenticated', aud: 'authenticated', exp: 4102444800 })}.sig`
const session = { access_token: jwt, token_type: 'bearer', expires_in: 3600, expires_at: 4102444800, refresh_token: 'r',
  user: { id: USER, aud: 'authenticated', email: 'crew@example.test', app_metadata: {}, user_metadata: { has_password: true } } }

// ---------------------------------------------------------------- the browser
const browser = await chromium.launch()
const context = await browser.newContext({ viewport: { width: 390, height: 844 }, geolocation: GEO, permissions: ['geolocation'] })
await context.addInitScript((s) => { try { localStorage.setItem('sb-mnlyltdxnvzbttugkmng-auth-token', JSON.stringify(s)) } catch {} }, session)
await context.route(SUPABASE, backend)
const page = await context.newPage()
const text = () => page.locator('body').innerText()
const outbox = () => page.evaluate(() => new Promise((resolve) => {
  const open = indexedDB.open('duly-crew', 1)
  open.onupgradeneeded = () => { open.result.createObjectStore('photo-outbox', { keyPath: 'id' }) }
  open.onsuccess = () => {
    const db = open.result
    if (!db.objectStoreNames.contains('photo-outbox')) return resolve([])
    const req = db.transaction('photo-outbox').objectStore('photo-outbox').getAll()
    req.onsuccess = () => { db.close(); resolve(req.result.map(({ blob, ...rest }) => ({ ...rest, size: blob.size }))) }
  }
}))
const goOffline = async () => { state.offline = true; await context.setOffline(true) }
const goOnline = async () => { state.offline = false; await context.setOffline(false) }
const photo = (page) => page.locator('input[type=file]').nth(1).setInputFiles({ name: 'after.jpg', mimeType: 'image/jpeg', buffer: Buffer.alloc(30_000, 7) })
const reset = () => { Object.assign(state.calls, { upload: 0, insert: 0, exists: 0, complete: 0, checkIn: 0 }); state.uploads = []; state.inserts = []; state.storage.clear(); state.failNext = { uploadAbort: 0, insertAbort: 0, insertRefuse: 0 }; state.failPaths.clear() }

async function openJob(waitFor = 'Surgery') {
  await page.goto(`${base}/crew/${JOB}`, { waitUntil: 'domcontentloaded' })
  await until(async () => (await text()).includes(waitFor), `the job sheet to show "${waitFor}"`)
}

// 1. With a signal a photo goes straight through.
seed(); await openJob()
await photo(page)
await until(() => state.calls.insert === 1, 'the photo to be sent')
check(state.calls.upload === 1 && state.calls.insert === 1, 'with a signal, the photo is uploaded and recorded straight away', JSON.stringify(state.calls))
check((await outbox()).length === 0, 'and nothing is kept on the phone')
check(!(await text()).includes('Saved on this phone'), 'and nothing says it was saved for later')
check(state.inserts[0]?.lat === GEO.latitude && state.inserts[0]?.lng === GEO.longitude && 'taken_at' in state.inserts[0] && !('uploaded_by' in state.inserts[0]), 'the record carries where and when it was taken', JSON.stringify(state.inserts[0]))

// 2. Without a signal it is kept on the phone, and the app says so.
reset(); await goOffline()
await until(async () => (await text()).includes("You're offline"), 'the offline notice')
check(true, "going offline shows the \"You're offline\" notice")
await photo(page)
await until(async () => (await text()).includes('Saved on this phone'), 'the photo to be saved for later')
const queued = await outbox()
check(queued.length === 1 && queued[0].status === 'waiting' && queued[0].size === 30000, 'the photo is kept on the phone, whole', JSON.stringify(queued.map((q) => q.size)))
check(state.calls.upload === 0 && state.calls.insert === 0, 'and nothing was sent', JSON.stringify(state.calls))
const t = await text()
check(/1 photo waiting to upload/.test(t), 'the top of the screen says one photo is waiting')
check(/saved on this phone, waiting to upload/.test(t), 'and the area shows it too')
const takenAt = queued[0].takenAt
check(queued[0].lat === GEO.latitude && queued[0].lng === GEO.longitude && queued[0].path.startsWith(`${JOB}/a`), 'with the place and the stored path fixed at the time', JSON.stringify([queued[0].lat, queued[0].lng, queued[0].path]))

// 3. Finishing is held while photos are waiting, and nothing is sent.
const finish = page.getByRole('button', { name: /Finish and send to client/ })
check(await finish.isVisible(), 'the Finish button is there (both areas are done on the server)')
await goOnline(); state.offline = true // the browser says online but the connection is still bad: nothing gets through
await finish.click()
await until(async () => /still waiting to upload/.test(await text()), 'the finish message')
check(state.calls.complete === 0, 'Finish is refused while a photo is waiting, and nothing reaches the server', JSON.stringify(state.calls))
check(/1 photo is still waiting to upload/.test(await text()), 'and says why, in plain words')
await goOffline()

// 4. The signal comes back: it sends by itself, with the original time and place, once.
const expectedPath = queued[0].path
await goOnline()
await until(() => state.calls.insert >= 1, 'the waiting photo to be sent on reconnect')
await until(async () => (await outbox()).length === 0, 'the outbox to empty')
check(state.storage.has(expectedPath) && state.calls.upload === 1, 'when the signal returns, it uploads by itself', JSON.stringify(state.calls))
const sent = state.inserts[0]
check(sent?.taken_at === takenAt && sent?.lat === GEO.latitude && sent?.storage_path === expectedPath, 'recorded with the time it was taken, not the time it was sent', JSON.stringify([sent?.taken_at, takenAt]))
check(state.evidence.filter((e) => e.storage_path === expectedPath).length === 1, 'exactly one evidence row for it')
await until(async () => !/waiting to upload/.test(await text()), 'the waiting notices to go')
check(true, 'the waiting notices go away')

// 5. A signal that drops mid-upload keeps the photo and retries it.
reset(); state.failNext.uploadAbort = 1
await photo(page)
await until(async () => (await text()).includes('Saved on this phone'), 'the dropped upload to be saved for later')
check((await outbox()).length === 1, 'a connection that drops mid-upload keeps the photo')
await page.getByRole('button', { name: 'Upload now' }).click()
await until(async () => (await outbox()).length === 0, 'the retry to finish')
check(state.evidence.filter((e) => e.storage_path === state.uploads[0]).length === 1 && state.calls.upload === 2, 'and the retry sends it once', JSON.stringify(state.calls))

// 6. A photo the server refuses is reported at once, and is not kept to retry forever.
reset(); state.failNext.insertRefuse = 1
await photo(page)
await until(async () => /row-level security/.test(await text()), 'the refusal to be shown')
check((await outbox()).length === 0, 'a refused photo is not queued (retrying would never help)')
check(true, 'and the reason is shown')

// 7. A crash between upload and recording heals without a duplicate.
reset(); state.failNext.insertAbort = 1
await photo(page)
await until(async () => (await text()).includes('Saved on this phone'), 'the half-finished send to be kept')
const path7 = state.uploads[0]
check(state.storage.has(path7) && !state.evidence.some((e) => e.storage_path === path7), 'the file arrived but its record did not')
await page.getByRole('button', { name: 'Upload now' }).click()
await until(async () => (await outbox()).length === 0, 'the half-finished send to be completed')
check(state.evidence.filter((e) => e.storage_path === path7).length === 1, 'the next attempt records it exactly once (the file was already there)', `rows=${state.evidence.filter((e) => e.storage_path === path7).length} uploads=${state.calls.upload}`)

// 8. Closing and reopening the app with photos waiting does not lose them, and a failed load says "no signal".
reset(); await goOffline()
await photo(page)
await until(async () => (await outbox()).length === 1, 'a photo to be kept')
await context.setOffline(false); state.offline = true // the phone thinks it is online but nothing gets through
await page.reload({ waitUntil: 'domcontentloaded' })
await until(async () => /couldn't load your account|No signal/.test(await text()), 'a plain no-signal message')
check((await outbox()).length === 1, 'closing and reopening the app keeps the waiting photo')
const bad = await text()
check(/couldn't load your account/.test(bad) && /Try again/.test(bad), 'a failed account lookup says so and offers to retry')
check(!/No access here yet|Join Duly Crew|Failed to fetch|TypeError/.test(bad), 'and does not call the person unauthorised, offer to sign them up, or show a browser error')
state.offline = false
await page.reload({ waitUntil: 'domcontentloaded' })
await until(async () => (await outbox()).length === 0, 'the waiting photo to go on reopening with a signal')
check(state.calls.insert >= 1 && (await outbox()).length === 0, 'and it is sent when the app is opened with a signal')

// 8b. The account loads but the job list does not: that is "no signal", never "no jobs assigned".
state.failPaths.add('/rest/v1/job_assignments')
await page.goto(`${base}/crew`, { waitUntil: 'domcontentloaded' })
await until(async () => /No signal/.test(await text()), 'the job list to report no signal')
const homeBad = await text()
check(!/No jobs assigned yet/.test(homeBad), 'a job list that failed to load is never shown as "No jobs assigned yet"')
check(/Try again/.test(homeBad), 'and offers to retry')
state.failPaths.clear()
await page.getByRole('button', { name: 'Try again' }).click()
await until(async () => /No jobs assigned yet/.test(await text()), 'the retry to load the (empty) list')
check(true, 'and the retry works once there is a signal')

// 8c. The job sheet itself failing to load is plain too, and retries.
state.failPaths.add('/rest/v1/jobs')
await page.goto(`${base}/crew/${JOB}`, { waitUntil: 'domcontentloaded' })
await until(async () => /No signal/.test(await text()), 'the job sheet to report no signal')
check(!/Failed to fetch|TypeError/.test(await text()), 'a job sheet that cannot load says "No signal", not a browser error')
state.failPaths.clear()
await page.getByRole('button', { name: 'Try again' }).click()
await until(async () => (await text()).includes('Surgery'), 'the job sheet after retrying')
check(true, 'and loads when you retry with a signal')

// 9. Check-in needs a real connection and says so plainly.
reset(); state.jobStatus = 'matched'
await openJob('check in')
await goOffline()
await page.getByRole('button', { name: /check in/i }).click()
await until(async () => /No signal/.test(await text()), 'the check-in message')
check(state.calls.checkIn === 0, 'checking in offline is refused (it would record the wrong time) and nothing is sent')
check(/Try again when you are back online/.test(await text()), 'in plain words, not a technical error')
check(!/Failed to fetch|TypeError/.test(await text()), 'with no browser error text')

await browser.close()
console.log(failed ? `\n${failed} check(s) failed` : '\nAll checks passed')
process.exit(failed ? 1 : 0)
