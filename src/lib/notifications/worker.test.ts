import assert from 'node:assert/strict'
import { test } from 'node:test'
import { handleSend, isAuthorised } from './worker.server.ts'

const req = (auth?: string, method = 'POST') => new Request('https://duly.example/api/notifications/send', { method, headers: auth ? { authorization: auth } : {} })
const full = { CRON_SECRET: 's3cret-value', SUPABASE_SERVICE_ROLE_KEY: 'service', RESEND_API_KEY: 'key', EMAIL_FROM: 'Duly <n@duly.example>', APP_URL: 'https://duly.example' }

test('the right bearer secret is accepted', () => {
  assert.equal(isAuthorised('Bearer s3cret-value', 's3cret-value'), true)
})

test('everything else is refused', () => {
  for (const [h, s] of [
    [null, 's3cret-value'], [undefined, 's3cret-value'], ['', 's3cret-value'],
    ['Bearer wrong', 's3cret-value'], ['Bearer s3cret-valu', 's3cret-value'], ['Bearer s3cret-value ', 's3cret-value'],
    ['bearer s3cret-value', 's3cret-value'], ['Basic s3cret-value', 's3cret-value'], ['s3cret-value', 's3cret-value'],
    ['Bearer ', 's3cret-value'], ['Bearer s3cret-value', ''], ['Bearer s3cret-value', undefined], ['Bearer ', ''],
  ] as [string | null | undefined, string | undefined][]) {
    assert.equal(isAuthorised(h, s), false, `${String(h)} vs ${String(s)}`)
  }
})

test('with no CRON_SECRET configured the endpoint is closed to everyone, even with a header', async () => {
  const res = await handleSend(req('Bearer anything'), { ...full, CRON_SECRET: undefined })
  assert.equal(res.status, 503)
})

test('a missing or wrong secret is a 401 and nothing else is checked or done', async () => {
  for (const auth of [undefined, 'Bearer nope']) {
    const res = await handleSend(req(auth), full)
    assert.equal(res.status, 401)
    assert.deepEqual(await res.json(), { error: 'unauthorised' })
  }
})

test('without the service key it is not configured', async () => {
  const res = await handleSend(req('Bearer s3cret-value'), { ...full, SUPABASE_SERVICE_ROLE_KEY: undefined })
  assert.equal(res.status, 503)
})

test('without an email provider it claims nothing, so queued emails wait until it is switched on', async () => {
  for (const missing of ['RESEND_API_KEY', 'EMAIL_FROM', 'APP_URL']) {
    const res = await handleSend(req('Bearer s3cret-value'), { ...full, [missing]: undefined })
    assert.equal(res.status, 200)
    assert.deepEqual(await res.json(), { configured: false, claimed: 0 })
  }
})

test('a refusal never reveals whether the secret or the rest of the setup is the problem', async () => {
  const wrong = await (await handleSend(req('Bearer nope'), full)).text()
  const none = await (await handleSend(req(), full)).text()
  assert.equal(wrong, none)
  assert.ok(!wrong.includes('s3cret') && !wrong.includes('service'))
})
