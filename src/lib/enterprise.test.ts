import assert from 'node:assert/strict'
import { test } from 'node:test'
import { pickEnterprise } from './enterprise.ts'
import { readFeatures } from './features.ts'

const org = (id: string, kind: 'buyer' | 'vendor', segment: string | null) => ({ id, name: id, kind, segment })

test('an Enterprise is a buyer organisation in the enterprise segment', () => {
  assert.equal(pickEnterprise([]), null)
  assert.equal(pickEnterprise([{ org_id: 'h', role: 'owner', org: org('h', 'buyer', 'homeowner') }]), null)
  assert.equal(pickEnterprise([{ org_id: 'v', role: 'vendor_admin', org: org('v', 'vendor', null) }]), null)
  const e = pickEnterprise([
    { org_id: 'h', role: 'owner', org: org('h', 'buyer', 'homeowner') },
    { org_id: 'e', role: 'viewer', org: org('e', 'buyer', 'enterprise') },
  ])
  assert.deepEqual(e, { id: 'e', name: 'e', canManage: false })
})

test('an Enterprise owner or approver can manage it, a viewer cannot', () => {
  const m = (role: 'owner' | 'approver' | 'viewer') => [{ org_id: 'e', role, org: org('e', 'buyer', 'enterprise') }]
  assert.equal(pickEnterprise(m('owner'))?.canManage, true)
  assert.equal(pickEnterprise(m('approver'))?.canManage, true)
  assert.equal(pickEnterprise(m('viewer'))?.canManage, false)
})

test('feature switches fail closed and ignore unknown keys', () => {
  assert.deepEqual(readFeatures(null), { buyer_signup: false, marketplace: false, shifts: false })
  assert.deepEqual(readFeatures([{ key: 'marketplace', enabled: true }, { key: 'nonsense', enabled: true }]), { buyer_signup: false, marketplace: true, shifts: false })
  assert.deepEqual(readFeatures([{ key: 'buyer_signup', enabled: true }, { key: 'marketplace', enabled: true }, { key: 'shifts', enabled: true }]), { buyer_signup: true, marketplace: true, shifts: true })
})

test('compliance rows are grouped by vendor in the order given, with what needs attention counted', async () => {
  const { groupByVendor, claimsToReview } = await import('./compliance.ts')
  const row = (vendor: string, kind: string, state: string) => ({
    vendor_org_id: vendor, vendor_name: vendor.toUpperCase(), roster_status: 'active', kind, state,
    claim_id: null, reference: null, valid_until: null, duly_status: null, reviewed_at: null, note: null,
  })
  const rows = [row('b', 'iso_9001', 'accepted'), row('b', 'chas', 'awaiting'), row('a', 'iso_9001', 'accepted'), row('a', 'chas', 'accepted'), row('c', 'chas', 'not_sent'), row('c', 'iso_9001', 'expired')]
  const g = groupByVendor(rows)
  assert.deepEqual(g.map((v) => v.vendor_org_id), ['b', 'a', 'c'])
  assert.deepEqual(g.map((v) => [v.accepted, v.needsReview, v.needsVendor, v.complete]), [[1, 1, 0, false], [2, 0, 0, true], [0, 0, 2, false]])
  assert.equal(claimsToReview(rows), 1)
  assert.deepEqual(groupByVendor([]), [])
})

test('every kind an Enterprise can require has a readable name', async () => {
  const { KIND_TEXT, REQUIRABLE_KINDS } = await import('./compliance.ts')
  for (const k of REQUIRABLE_KINDS) assert.ok(KIND_TEXT[k] && KIND_TEXT[k] !== k, k)
  assert.equal(REQUIRABLE_KINDS.includes('dbs' as never), false)
})

test('the delivery view counts what needs attention and words it plainly', async () => {
  const { deliveryCounts, deliveryText, deliveryDates, openFor } = await import('./delivery.ts')
  const rows = [{ attention: 'missed' }, { attention: 'late' }, { attention: 'late' }, { attention: 'awaiting_check' }, { attention: null }, { attention: 'unknown' }]
  assert.deepEqual(deliveryCounts(rows), { missed: 1, late: 2, no_crew: 0, overrunning: 0, held: 0, awaiting_check: 1, total: 4, problems: 3 })
  const r = { attention: 'late', late_minutes: 25, on_site_minutes: null, planned_minutes: 90, vendor_name: 'Walk Cleaners', site_name: 'Hospital' }
  assert.equal(deliveryText(r), '25 min late: Walk Cleaners has not checked in')
  assert.match(deliveryText({ ...r, attention: 'missed' }), /Nobody came/)
  assert.equal(deliveryText({ ...r, attention: null }), '')
  const today = new Date(2026, 10, 19)
  assert.deepEqual(deliveryDates('today', today), { from: '2026-11-19', to: '2026-11-19' })
  assert.deepEqual(deliveryDates('last7', today), { from: '2026-11-13', to: '2026-11-19' })
  assert.deepEqual(deliveryDates('last30', today), { from: '2026-10-21', to: '2026-11-19' })
  assert.deepEqual(deliveryDates('next7', today), { from: '2026-11-19', to: '2026-11-26' })
  assert.equal(openFor(0), 'just now')
  assert.equal(openFor(5), '5 h')
  assert.equal(openFor(72), '3 days')
})
