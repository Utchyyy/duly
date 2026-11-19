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
