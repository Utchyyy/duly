import assert from 'node:assert/strict'
import { test } from 'node:test'
import { absoluteLink, escapeHtml, oneLine, renderEmail } from './email.ts'
import type { ClaimedNotification } from './email.ts'

const base: ClaimedNotification = {
  id: 'n1', email: 'person@example.test', title: 'A quote has arrived', body: 'Clean-Fit quoted for "Weekly clean".',
  link: '/briefs/abc', category: 'quotes', created_at: '2026-11-07T12:00:00Z',
}

test('an email carries the title, body and an absolute link into the app', () => {
  const e = renderEmail(base, 'https://duly.example')
  assert.equal(e.to, 'person@example.test')
  assert.equal(e.subject, 'A quote has arrived')
  assert.ok(e.text.includes('Clean-Fit quoted for "Weekly clean".'))
  assert.ok(e.text.includes('Open in Duly: https://duly.example/briefs/abc'))
  assert.ok(e.html.includes('href="https://duly.example/briefs/abc"'))
})

test('every email says how to change notification settings', () => {
  const e = renderEmail(base, 'https://duly.example/')
  assert.ok(e.text.includes('https://duly.example/account'))
  assert.ok(e.html.includes('href="https://duly.example/account"'))
})

test('a trailing slash on the app URL does not double up', () => {
  assert.equal(absoluteLink('https://duly.example/', '/jobs/1'), 'https://duly.example/jobs/1')
  assert.equal(absoluteLink('https://duly.example///', '/jobs/1'), 'https://duly.example/jobs/1')
})

test('only in-app paths become links', () => {
  for (const bad of ['//evil.example/x', 'https://evil.example', 'javascript:alert(1)', 'jobs/1', '/a b', '/a\\b', '', null, undefined]) {
    assert.equal(absoluteLink('https://duly.example', bad), null, `${String(bad)} must not become a link`)
  }
  assert.equal(absoluteLink('https://duly.example', '/'), 'https://duly.example/')
})

test('an email with no usable link has no button and no stray URL', () => {
  const e = renderEmail({ ...base, link: 'https://evil.example/phish' }, 'https://duly.example')
  assert.ok(!e.html.includes('evil.example'))
  assert.ok(!e.text.includes('evil.example'))
  assert.ok(!e.html.includes('Open in Duly</a>'))
})

test('markup in a notification is escaped in the HTML part', () => {
  const e = renderEmail({ ...base, title: '<script>alert(1)</script>', body: '"><img src=x onerror=alert(1)> & more' }, 'https://duly.example')
  assert.ok(!e.html.includes('<script>'))
  assert.ok(!e.html.includes('<img'))
  assert.ok(e.html.includes('&lt;script&gt;'))
  assert.ok(e.html.includes('&amp; more'))
  assert.equal(escapeHtml(`<a href="x">'&'</a>`), '&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;')
})

test('a subject can never contain a line break (no header injection)', () => {
  const e = renderEmail({ ...base, title: 'Hello\r\nBcc: attacker@example.test\n\nbody' }, 'https://duly.example')
  assert.ok(!/[\r\n]/.test(e.subject))
  assert.equal(oneLine('a b\nc'), 'a b c')
  assert.ok(oneLine('x'.repeat(500)).length <= 120)
})

test('the recipient is exactly the claimed address, and nothing else is added as a recipient', () => {
  const e = renderEmail({ ...base, email: 'only-this@example.test' }, 'https://duly.example')
  assert.deepEqual(Object.keys(e).sort(), ['html', 'subject', 'text', 'to'])
  assert.equal(e.to, 'only-this@example.test')
})

test('the email loads nothing from elsewhere', () => {
  const e = renderEmail(base, 'https://duly.example')
  assert.ok(!/<img|<link|<script|url\(|@import/i.test(e.html))
})
