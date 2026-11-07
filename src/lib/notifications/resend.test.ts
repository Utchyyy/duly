import assert from 'node:assert/strict'
import { test } from 'node:test'
import { resendSender } from './resend.server.ts'

const email = { to: 'a@example.test', subject: 'Subject', text: 'text', html: '<p>html</p>' }
type Call = { url: string; init: RequestInit }
function fake(status: number, body = '{"message":"echoes a@example.test"}') {
  const calls: Call[] = []
  const fetchImpl = (async (url: string, init: RequestInit) => (calls.push({ url, init }), new Response(body, { status }))) as typeof fetch
  return { calls, send: resendSender({ apiKey: 'KEY', from: 'Duly <n@duly.example>', fetchImpl }) }
}

test('it posts one email to Resend with the key and an idempotency key', async () => {
  const { calls, send } = fake(200)
  assert.deepEqual(await send(email, 'notif-1'), { ok: true })
  assert.equal(calls.length, 1)
  assert.equal(calls[0]?.url, 'https://api.resend.com/emails')
  const headers = calls[0]?.init.headers as Record<string, string>
  assert.equal(headers.Authorization, 'Bearer KEY')
  assert.equal(headers['Idempotency-Key'], 'notif-1')
  assert.deepEqual(JSON.parse(String(calls[0]?.init.body)), { from: 'Duly <n@duly.example>', to: ['a@example.test'], subject: 'Subject', text: 'text', html: '<p>html</p>' })
})

test('failures become a short code and never include the provider response', async () => {
  for (const [status, expected] of [[429, 'provider rate limit'], [422, 'provider 422'], [500, 'provider 500']] as const) {
    const r = await fake(status).send(email, 'k')
    assert.deepEqual(r, { ok: false, error: expected })
  }
})

test('a network failure is reported without the underlying message', async () => {
  const send = resendSender({ apiKey: 'KEY', from: 'x', fetchImpl: (async () => { throw new Error('connect ECONNREFUSED with KEY') }) as typeof fetch })
  const r = await send(email, 'k')
  assert.deepEqual(r, { ok: false, error: 'network error' })
})

test('the API key is only ever sent to Resend', async () => {
  const { calls, send } = fake(200)
  await send(email, 'k')
  assert.ok(!String(calls[0]?.init.body).includes('KEY'))
  assert.ok(calls.every((c) => c.url.startsWith('https://api.resend.com/')))
})
