import assert from 'node:assert/strict'
import { test } from 'node:test'
import { SendError, classifyError, deliver, flushOutbox, friendlyError, submitPhoto } from './outbox.ts'
import type { NewPhoto, OutboxEntry, OutboxStore, PhotoSink } from './outbox.ts'

const ME = 'user-me'
const photo = (n: number, over: Partial<NewPhoto> = {}): NewPhoto => ({
  id: `id-${n}`, userId: ME, jobId: 'job-1', areaId: `area-${n}`, kind: 'photo_after', path: `job-1/area-${n}/170000000000${n}-photo_after.jpg`,
  mime: 'image/jpeg', blob: new Blob([`photo ${n}`]), lat: 51.89 + n / 1000, lng: 0.9, takenAt: `2026-11-07T10:0${n}:00.000Z`, createdAt: `2026-11-07T10:0${n}:30.000Z`, ...over,
})

function memoryStore(listAll = false) {
  const rows = new Map<string, OutboxEntry>()
  const store: OutboxStore = {
    list: async (userId) => [...rows.values()].filter((e) => listAll || e.userId === userId).map((e) => ({ ...e })),
    put: async (e) => void rows.set(e.id, { ...e }),
    remove: async (id) => void rows.delete(id),
  }
  return { store, rows }
}

/** A pretend Supabase: files and evidence rows live in maps; failures can be scripted per call. */
function fakeSink(script: { upload?: (n: number) => void; exists?: (n: number) => void; insert?: (n: number) => void } = {}) {
  const files = new Map<string, Blob>()
  const evidence: { storage_path: string; taken_at: string; lat: number | null; lng: number | null; area_id: string }[] = []
  const calls = { upload: 0, exists: 0, insert: 0, log: [] as string[] }
  const sink: PhotoSink = {
    async upload(path, blob) { calls.upload += 1; calls.log.push(`upload ${path}`); script.upload?.(calls.upload); files.set(path, blob) },
    async evidenceExists(path) { calls.exists += 1; script.exists?.(calls.exists); return evidence.some((e) => e.storage_path === path) },
    async insertEvidence(row) {
      calls.insert += 1; calls.log.push(`insert ${row.storage_path}`); script.insert?.(calls.insert)
      // The database has a unique index on storage_path, and the real sink treats that violation as "already recorded".
      if (evidence.some((e) => e.storage_path === row.storage_path)) return
      evidence.push(row)
    },
  }
  return { sink, files, evidence, calls }
}
const network = () => { throw new SendError('network', 'Failed to fetch') }
const refused = () => { throw new SendError('rejected', 'new row violates row-level security policy') }
const signedOut = () => { throw new SendError('auth', 'JWT expired') }
let online = true
const goOnline = () => (online = true)
const goOffline = () => (online = false)
const isOnline = () => online

test('online: a photo is uploaded and its evidence row added, with when and where it was taken', async () => {
  goOnline()
  const { store, rows } = memoryStore(); const { sink, files, evidence, calls } = fakeSink()
  assert.equal(await submitPhoto({ store, sink, online: isOnline }, photo(1)), 'sent')
  assert.equal(rows.size, 0)
  assert.equal(files.size, 1)
  assert.deepEqual(calls.log, ['upload job-1/area-1/1700000000001-photo_after.jpg', 'insert job-1/area-1/1700000000001-photo_after.jpg'])
  assert.deepEqual(evidence[0], { job_id: 'job-1', area_id: 'area-1', kind: 'photo_after', storage_path: 'job-1/area-1/1700000000001-photo_after.jpg', taken_at: '2026-11-07T10:01:00.000Z', lat: 51.891, lng: 0.9 })
})

test('offline: the photo is kept on the phone with everything needed, and nothing is sent', async () => {
  goOffline()
  const { store, rows } = memoryStore(); const { sink, calls } = fakeSink()
  assert.equal(await submitPhoto({ store, sink, online: isOnline }, photo(2)), 'queued')
  assert.equal(calls.upload + calls.exists + calls.insert, 0)
  const kept = rows.get('id-2')!
  assert.equal(kept.status, 'waiting')
  assert.equal(kept.takenAt, '2026-11-07T10:02:00.000Z')
  assert.equal(kept.lat, 51.892)
  assert.equal(kept.path, 'job-1/area-2/1700000000002-photo_after.jpg')
  assert.equal(kept.blob.size, 'photo 2'.length)
  goOnline()
})

test('a signal that drops mid-upload, or an expired sign-in, keeps the photo instead of losing it', async () => {
  goOnline()
  for (const failure of [network, signedOut]) {
    const { store, rows } = memoryStore(); const { sink } = fakeSink({ upload: failure })
    assert.equal(await submitPhoto({ store, sink, online: isOnline }, photo(3)), 'queued')
    assert.equal(rows.size, 1)
  }
})

test('a refusal by the server is shown straight away and is not queued (retrying would never help)', async () => {
  goOnline()
  const { store, rows } = memoryStore(); const { sink } = fakeSink({ insert: refused })
  await assert.rejects(submitPhoto({ store, sink, online: isOnline }, photo(4)), (e: unknown) => e instanceof SendError && e.kind === 'rejected')
  assert.equal(rows.size, 0)
})

test('delivering the same photo twice makes one file and one evidence row', async () => {
  const { sink, evidence, files } = fakeSink()
  const p = photo(1)
  await deliver(sink, p); await deliver(sink, p)
  assert.equal(evidence.length, 1)
  assert.equal(files.size, 1)
})

test('a crash between the upload and the evidence row is healed on the next attempt, without a duplicate', async () => {
  goOnline()
  const { store, rows } = memoryStore(); const { sink, evidence, calls } = fakeSink({ insert: (n) => { if (n === 1) network() } })
  assert.equal(await submitPhoto({ store, sink, online: isOnline }, photo(1)), 'queued')
  assert.equal(evidence.length, 0)
  const r = await flushOutbox({ store, sink, online: isOnline, userId: ME })
  assert.deepEqual([r.sent, r.waiting, r.failed], [1, 0, 0])
  assert.equal(evidence.length, 1)
  assert.equal(rows.size, 0)
  assert.equal(calls.insert, 2)
})

test('two flushes at once cannot create duplicate evidence', async () => {
  goOnline()
  const { store } = memoryStore(); const { sink, evidence } = fakeSink()
  goOffline(); await submitPhoto({ store, sink, online: isOnline }, photo(1)); await submitPhoto({ store, sink, online: isOnline }, photo(2)); goOnline()
  await Promise.all([flushOutbox({ store, sink, online: isOnline, userId: ME }), flushOutbox({ store, sink, online: isOnline, userId: ME })])
  assert.equal(new Set(evidence.map((e) => e.storage_path)).size, evidence.length, 'no path appears twice')
  assert.equal(evidence.length, 2)
})

test('flush sends oldest first and empties the outbox', async () => {
  goOffline()
  const { store, rows } = memoryStore(); const { sink, calls } = fakeSink()
  for (const n of [3, 1, 2]) await submitPhoto({ store, sink, online: isOnline }, photo(n))
  goOnline()
  const r = await flushOutbox({ store, sink, online: isOnline, userId: ME })
  assert.deepEqual([r.sent, r.waiting, r.failed, r.stoppedBy], [3, 0, 0, null])
  assert.deepEqual(calls.log.filter((l) => l.startsWith('upload')).map((l) => l.split('/')[1]), ['area-1', 'area-2', 'area-3'])
  assert.equal(rows.size, 0)
})

test('flush stops when the signal goes, keeps what is left, and loses nothing', async () => {
  goOffline()
  const { store, rows } = memoryStore(); const sinkA = fakeSink()
  for (const n of [1, 2, 3]) await submitPhoto({ store, sink: sinkA.sink, online: isOnline }, photo(n))
  goOnline()
  const { sink, evidence } = fakeSink({ upload: (n) => { if (n === 2) network() } })
  const r = await flushOutbox({ store, sink, online: isOnline, userId: ME })
  assert.deepEqual([r.sent, r.waiting, r.stoppedBy], [1, 2, 'offline'])
  assert.deepEqual([...rows.keys()].sort(), ['id-2', 'id-3'])
  assert.equal(evidence.length, 1)
  const again = await flushOutbox({ store, sink, online: isOnline, userId: ME })
  assert.deepEqual([again.sent, again.waiting], [2, 0])
  assert.equal(rows.size, 0)
})

test('flush does nothing at all while offline', async () => {
  goOffline()
  const { store, rows } = memoryStore(); const { sink, calls } = fakeSink()
  await submitPhoto({ store, sink, online: isOnline }, photo(1))
  const r = await flushOutbox({ store, sink, online: isOnline, userId: ME })
  assert.deepEqual([r.sent, r.waiting, r.stoppedBy], [0, 1, 'offline'])
  assert.equal(calls.upload, 0)
  assert.equal(rows.size, 1)
  goOnline()
})

test('flush stops, without losing anything, if the person has been signed out', async () => {
  goOffline()
  const { store, rows } = memoryStore(); await submitPhoto({ store, sink: fakeSink().sink, online: isOnline }, photo(1)); goOnline()
  const r = await flushOutbox({ store, sink: fakeSink({ upload: signedOut }).sink, online: isOnline, userId: ME })
  assert.deepEqual([r.sent, r.stoppedBy], [0, 'auth'])
  assert.equal(rows.size, 1)
})

test('a photo the server refuses is parked as failed with the reason, and the others still go', async () => {
  goOffline()
  const { store, rows } = memoryStore(); const filler = fakeSink()
  for (const n of [1, 2, 3]) await submitPhoto({ store, sink: filler.sink, online: isOnline }, photo(n))
  goOnline()
  const { sink, evidence } = fakeSink({ insert: (n) => { if (n === 2) refused() } })
  const r = await flushOutbox({ store, sink, online: isOnline, userId: ME })
  assert.deepEqual([r.sent, r.failed, r.waiting], [2, 1, 0])
  assert.equal(evidence.length, 2)
  const parked = rows.get('id-2')!
  assert.equal(parked.status, 'failed')
  assert.match(parked.lastError ?? '', /row-level security/)
  assert.equal(parked.attempts, 1)
  assert.equal(parked.blob.size > 0, true, 'the photo itself is still there')
})

test('parked photos are left alone unless the person asks to retry them', async () => {
  goOffline()
  const { store, rows } = memoryStore(); await submitPhoto({ store, sink: fakeSink().sink, online: isOnline }, photo(1)); goOnline()
  await flushOutbox({ store, sink: fakeSink({ insert: refused }).sink, online: isOnline, userId: ME })
  assert.equal(rows.get('id-1')!.status, 'failed')
  const good = fakeSink()
  const skipped = await flushOutbox({ store, sink: good.sink, online: isOnline, userId: ME })
  assert.deepEqual([skipped.sent, skipped.failed], [0, 1])
  assert.equal(good.calls.upload, 0)
  const retried = await flushOutbox({ store, sink: good.sink, online: isOnline, userId: ME, includeFailed: true })
  assert.deepEqual([retried.sent, retried.failed], [1, 0])
  assert.equal(rows.size, 0)
})

test("one person's photos are never sent as another person's", async () => {
  goOffline()
  const { store, rows } = memoryStore(true); const filler = fakeSink()
  await submitPhoto({ store, sink: filler.sink, online: isOnline }, photo(1, { userId: 'someone-else', id: 'theirs' }))
  await submitPhoto({ store, sink: filler.sink, online: isOnline }, photo(2))
  goOnline()
  const { sink, calls } = fakeSink()
  const r = await flushOutbox({ store, sink, online: isOnline, userId: ME })
  assert.equal(r.sent, 1)
  assert.equal(calls.upload, 1)
  assert.deepEqual([...rows.keys()], ['theirs'])
})

test('the time and place stored when the photo was taken survive being sent hours later', async () => {
  goOffline()
  const { store } = memoryStore(); await submitPhoto({ store, sink: fakeSink().sink, online: isOnline }, photo(5, { takenAt: '2026-11-07T08:15:00.000Z', lat: 51.5, lng: -0.1 })); goOnline()
  const { sink, evidence } = fakeSink()
  await flushOutbox({ store, sink, online: isOnline, userId: ME })
  assert.equal(evidence[0]?.taken_at, '2026-11-07T08:15:00.000Z')
  assert.equal(evidence[0]?.lat, 51.5)
  assert.equal(evidence[0]?.lng, -0.1)
})

test('failures are sorted into no signal, signed out, or refused', () => {
  const cases: [unknown, string][] = [
    [new TypeError('Failed to fetch'), 'network'],
    [{ message: 'Failed to fetch' }, 'network'],
    [{ message: 'Load failed' }, 'network'],
    [{ message: 'The network connection was lost.' }, 'network'],
    [{ name: 'AbortError', message: 'x' }, 'network'],
    [{ status: 503, message: 'x' }, 'network'],
    [{ status: 429, message: 'x' }, 'network'],
    [{ status: 401, message: 'x' }, 'auth'],
    [{ message: 'JWT expired' }, 'auth'],
    [{ code: 'PGRST301', message: 'x' }, 'auth'],
    [{ code: '42501', message: 'new row violates row-level security policy' }, 'rejected'],
    [{ statusCode: '413', message: 'The object exceeded the maximum allowed size' }, 'rejected'],
    [{ statusCode: 400, message: 'mime type text/html is not supported' }, 'rejected'],
    ['Failed to fetch', 'network'],
    [new SendError('auth', 'x'), 'auth'],
    [null, 'rejected'],
    [undefined, 'rejected'],
    [42, 'rejected'],
  ]
  for (const [input, expected] of cases) assert.equal(classifyError(input), expected, JSON.stringify(input) ?? String(input))
})

test('what people read when something fails is plain, and a server reason is passed through', () => {
  assert.match(friendlyError(new TypeError('Failed to fetch')), /No signal/)
  assert.match(friendlyError({ message: 'JWT expired' }), /signed out/)
  assert.equal(friendlyError(new Error('This job is completed and cannot be checked into')), 'This job is completed and cannot be checked into')
  assert.equal(friendlyError({ message: 'You are not on this job' }), 'You are not on this job')
  assert.match(friendlyError(undefined), /Something went wrong/)
})
