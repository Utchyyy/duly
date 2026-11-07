import assert from 'node:assert/strict'
import { test } from 'node:test'
import type { Duly } from '../supabase.ts'
import { SendError } from './outbox.ts'
import { supabaseSink } from './supabase-sink.ts'

type Err = { message: string; code?: string; statusCode?: string } | null

/** Just enough of the Supabase client for the three calls the sink makes. */
function fakeDb(r: { upload?: Err | 'throw'; select?: { data: unknown[] | null; error: Err } | 'throw'; insert?: Err | 'throw' } = {}) {
  const calls: string[] = []
  const db = {
    storage: { from: (bucket: string) => ({ upload: async (path: string) => { calls.push(`upload ${bucket}/${path}`); if (r.upload === 'throw') throw new TypeError('Failed to fetch'); return { error: r.upload ?? null } } }) },
    from: (table: string) => ({
      select: () => ({ eq: () => ({ limit: async () => { calls.push(`select ${table}`); if (r.select === 'throw') throw new TypeError('Failed to fetch'); return r.select ?? { data: [], error: null } } }) }),
      insert: async (row: unknown) => { calls.push(`insert ${table} ${JSON.stringify(row)}`); if (r.insert === 'throw') throw new TypeError('Failed to fetch'); return { error: r.insert ?? null } },
    }),
  }
  return { db: db as unknown as Duly, calls }
}
const kind = (k: string) => (e: unknown) => e instanceof SendError && e.kind === k
const row = { job_id: 'j', area_id: 'a', kind: 'photo_after' as const, storage_path: 'j/a/1-photo_after.jpg', taken_at: '2026-11-07T08:00:00Z', lat: 1, lng: 2 }

test('upload goes to the evidence bucket with the photo type', async () => {
  const { db, calls } = fakeDb()
  await supabaseSink(db).upload('j/a/1.jpg', new Blob(['x']), 'image/png')
  assert.deepEqual(calls, ['upload evidence/j/a/1.jpg'])
})

test('a file that is already there counts as uploaded', async () => {
  for (const err of [{ message: 'The resource already exists', statusCode: '409' }, { message: 'Duplicate' }, { message: 'x', statusCode: '409' }]) {
    await supabaseSink(fakeDb({ upload: err }).db).upload('p', new Blob(['x']), 'image/jpeg')
  }
})

test('upload failures keep their meaning: no signal, signed out, refused', async () => {
  await assert.rejects(supabaseSink(fakeDb({ upload: 'throw' }).db).upload('p', new Blob(['x']), 'image/jpeg'), kind('network'))
  await assert.rejects(supabaseSink(fakeDb({ upload: { message: 'Failed to fetch' } }).db).upload('p', new Blob(['x']), 'image/jpeg'), kind('network'))
  await assert.rejects(supabaseSink(fakeDb({ upload: { message: 'JWT expired' } }).db).upload('p', new Blob(['x']), 'image/jpeg'), kind('auth'))
  await assert.rejects(supabaseSink(fakeDb({ upload: { message: 'new row violates row-level security policy', statusCode: '403' } }).db).upload('p', new Blob(['x']), 'image/jpeg'), kind('rejected'))
  await assert.rejects(supabaseSink(fakeDb({ upload: { message: 'The object exceeded the maximum allowed size', statusCode: '413' } }).db).upload('p', new Blob(['x']), 'image/jpeg'), kind('rejected'))
})

test('the evidence row is only looked up by its stored path', async () => {
  const yes = fakeDb({ select: { data: [{ id: '1' }], error: null } })
  assert.equal(await supabaseSink(yes.db).evidenceExists('p'), true)
  assert.equal(await supabaseSink(fakeDb({ select: { data: [], error: null } }).db).evidenceExists('p'), false)
  await assert.rejects(supabaseSink(fakeDb({ select: 'throw' }).db).evidenceExists('p'), kind('network'))
})

test('inserting evidence that is already recorded (unique violation) counts as done', async () => {
  const { db, calls } = fakeDb({ insert: { message: 'duplicate key value violates unique constraint "evidence_storage_path_key"', code: '23505' } })
  await supabaseSink(db).insertEvidence(row)
  assert.equal(calls.length, 1)
})

test('every other insert failure stays a failure', async () => {
  await assert.rejects(supabaseSink(fakeDb({ insert: { message: 'new row violates row-level security policy', code: '42501' } }).db).insertEvidence(row), kind('rejected'))
  await assert.rejects(supabaseSink(fakeDb({ insert: { message: 'JWT expired', code: 'PGRST301' } }).db).insertEvidence(row), kind('auth'))
  await assert.rejects(supabaseSink(fakeDb({ insert: 'throw' }).db).insertEvidence(row), kind('network'))
})

test('the evidence row carries the original time and place, and no uploader (the database fills that in)', async () => {
  const { db, calls } = fakeDb()
  await supabaseSink(db).insertEvidence(row)
  const sent = JSON.parse(calls[0]!.replace(/^insert evidence /, ''))
  assert.deepEqual(sent, row)
  assert.ok(!('uploaded_by' in sent))
})
