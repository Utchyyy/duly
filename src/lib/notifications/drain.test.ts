import assert from 'node:assert/strict'
import { test } from 'node:test'
import { drainEmails } from './drain.ts'
import type { DrainDeps, SendResult } from './drain.ts'
import type { ClaimedNotification, OutgoingEmail } from './email.ts'

const row = (id: string, email = `${id}@example.test`): ClaimedNotification => ({
  id, email, title: `Title ${id}`, body: 'Body', link: `/jobs/${id}`, category: 'jobs', created_at: '2026-11-07T12:00:00Z',
})

function setup(batches: ClaimedNotification[][], over: Partial<DrainDeps> = {}) {
  const log = { claims: [] as number[], finished: [] as [string, boolean, string | undefined][], sent: [] as [OutgoingEmail, string][] }
  let clock = 0
  const queue = [...batches]
  const deps: DrainDeps = {
    appUrl: 'https://duly.example',
    now: () => clock,
    claim: async (limit) => (log.claims.push(limit), queue.shift() ?? []),
    send: async (email, key): Promise<SendResult> => (log.sent.push([email, key]), { ok: true }),
    finish: async (id, sent, error) => void log.finished.push([id, sent, error]),
    ...over,
  }
  return { deps, log, tick: (ms: number) => void (clock += ms) }
}

test('claimed emails are sent to their own address and reported sent', async () => {
  const { deps, log } = setup([[row('a'), row('b')]])
  const s = await drainEmails(deps)
  assert.deepEqual(s, { claimed: 2, sent: 2, failed: 0, errors: 0 })
  assert.deepEqual(log.sent.map(([e]) => e.to), ['a@example.test', 'b@example.test'])
  assert.deepEqual(log.finished, [['a', true, undefined], ['b', true, undefined]])
})

test('the notification id is the idempotency key, so a repeat send is harmless', async () => {
  const { deps, log } = setup([[row('abc-123')]])
  await drainEmails(deps)
  assert.equal(log.sent[0]?.[1], 'abc-123')
})

test('a provider failure is reported as failed with its reason, and the rest still go', async () => {
  const { deps, log } = setup([[row('a'), row('b'), row('c')]], {
    send: async (e): Promise<SendResult> => (e.to.startsWith('b') ? { ok: false, error: 'provider 422' } : { ok: true }),
  })
  const s = await drainEmails(deps)
  assert.deepEqual(s, { claimed: 3, sent: 2, failed: 1, errors: 0 })
  assert.deepEqual(log.finished.map(([id, ok]) => `${id}:${ok}`), ['a:true', 'b:false', 'c:true'])
  assert.equal(log.finished[1]?.[2], 'provider 422')
})

test('a thrown error while sending is a failure with a generic reason (nothing leaks)', async () => {
  const { deps, log } = setup([[row('a')]], { send: async () => { throw new Error('secret token abc leaked in message') } })
  const s = await drainEmails(deps)
  assert.equal(s.failed, 1)
  assert.equal(log.finished[0]?.[2], 'send failed')
  assert.ok(!JSON.stringify(log.finished).includes('secret'))
})

test('if reporting the outcome fails, it is counted and the run carries on', async () => {
  let n = 0
  const { deps, log } = setup([[row('a'), row('b')]], { finish: async (id, sent) => { n += 1; if (n === 1) throw new Error('db down'); log.finished.push([id, sent, undefined]) } })
  const s = await drainEmails(deps)
  assert.deepEqual(s, { claimed: 2, sent: 1, failed: 0, errors: 1 })
  assert.equal(log.sent.length, 2)
})

test('it stops when nothing is due', async () => {
  const { deps, log } = setup([[]])
  const s = await drainEmails(deps)
  assert.deepEqual(s, { claimed: 0, sent: 0, failed: 0, errors: 0 })
  assert.deepEqual(log.claims, [20])
  assert.equal(log.sent.length, 0)
})

test('it keeps claiming while batches come back full, and stops at a short batch', async () => {
  const { deps, log } = setup([[row('1'), row('2')], [row('3'), row('4')], [row('5')], [row('never')]])
  const s = await drainEmails(deps, { batch: 2 })
  assert.equal(s.claimed, 5)
  assert.equal(log.claims.length, 3)
  assert.ok(!log.finished.some(([id]) => id === 'never'))
})

test('it never does more than the maximum number of batches', async () => {
  const { deps, log } = setup(Array.from({ length: 10 }, (_, i) => [row(`x${i}a`), row(`x${i}b`)]))
  await drainEmails(deps, { batch: 2, maxBatches: 3 })
  assert.equal(log.claims.length, 3)
})

test('it stops when the time budget is spent', async () => {
  let t = 0
  const { deps, log } = setup(Array.from({ length: 10 }, (_, i) => [row(`y${i}a`), row(`y${i}b`)]), { now: () => t, claim: undefined })
  deps.claim = async (limit) => { log.claims.push(limit); t += 30_000; return [row(`z${t}a`), row(`z${t}b`)] }
  await drainEmails(deps, { batch: 2, maxBatches: 10, budgetMs: 45_000 })
  assert.equal(log.claims.length, 2)
})

test('the same notification is never sent twice in one run', async () => {
  const { deps, log } = setup([[row('dup'), row('dup')], [row('dup'), row('other')]])
  await drainEmails(deps, { batch: 2 })
  assert.deepEqual(log.sent.map(([, k]) => k), ['dup', 'other'])
})

test('unsafe content cannot break the run: it is rendered escaped and sent', async () => {
  const bad = { ...row('evil'), title: '<b>x</b>\r\nBcc: a@b.c', body: '<script>1</script>', link: '//evil.example' }
  const { deps, log } = setup([[bad]])
  const s = await drainEmails(deps)
  assert.equal(s.sent, 1)
  const [email] = log.sent[0]!
  assert.ok(!/[\r\n]/.test(email.subject))
  assert.ok(!email.html.includes('<script>') && !email.html.includes('evil.example'))
})
