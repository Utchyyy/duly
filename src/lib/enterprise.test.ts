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
    claim_id: null, reference: null, valid_until: null, duly_status: null, reviewed_at: null, note: null, evidence_path: null,
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

test('months move as the first of the month and read as words', async () => {
  const { monthStart, shiftMonth, monthLabel, thisMonth } = await import('./sla.ts')
  assert.equal(monthStart('2026-11-19'), '2026-11-01')
  assert.equal(shiftMonth('2026-11-19', -1), '2026-10-01')
  assert.equal(shiftMonth('2026-01-31', -1), '2025-12-01')
  assert.equal(shiftMonth('2026-12-05', 1), '2027-01-01')
  assert.equal(monthLabel('2026-11-19'), 'November 2026')
  assert.equal(thisMonth(new Date(2026, 10, 19)), '2026-11-01')
})

test('the SLA CSV quotes cells and defuses anything a spreadsheet would run as a formula', async () => {
  const { csvCell, packCsv, exceptionsCsv, packFileName, csvBasis } = await import('./sla.ts')
  assert.equal(csvCell('plain'), 'plain')
  assert.equal(csvCell('a, b'), '"a, b"')
  assert.equal(csvCell('say "hi"'), '"say ""hi"""')
  assert.equal(csvCell('=HYPERLINK("http://x")'), '"\'=HYPERLINK(""http://x"")"')
  assert.equal(csvCell('+1'), "'+1")
  assert.equal(csvCell('-2'), "'-2")
  assert.equal(csvCell('@SUM(A1)'), "'@SUM(A1)")
  assert.equal(csvCell(-5), '-5')
  assert.equal(csvCell(null), '')
  assert.equal(csvCell(true), 'Yes')
  const row = {
    vendor_org_id: 'v1', vendor_name: '=Evil Ltd', site_name: null, is_vendor_total: true, scheduled_visits: 5, due_visits: 5, checked_in_visits: 3, evidenced_visits: 3, evidenced_rate: 0.6,
    on_time_visits: 2, on_time_rate: 0.667, late_visits: 1, missed_visits: 2, avg_late_minutes: 16.7, plan_followed_rate: 1, first_time_right_rate: 0.667, complaints: 2,
    complaints_per_100: 40, open_complaints: 1, sla_breaches: 2, on_time_target: 0.95, evidenced_target: null, max_complaints_per_100: 5, on_time_met: false, evidenced_met: null, complaints_met: false,
  }
  const csv = packCsv('2026-09-01', 'Soft FM, One', [row], 'Frozen 2026-10-03')
  const lines = csv.replace('﻿', '').trim().split('\r\n')
  assert.equal(lines.length, 2)
  assert.match(lines[1], /^September 2026,Frozen 2026-10-03,"Soft FM, One",'=Evil Ltd,All sites,Vendor,5,5,3,3,60,2,66.7,1,2,16.7,100,66.7,2,40,1,2,95,Not met,,,5,Not met$/)
  assert.ok(csv.startsWith('﻿'))
  const ex = exceptionsCsv('2026-09-01', 'E', [{ vendor_name: 'V', site_name: 'S', scheduled_start: '2026-09-03T10:00:00Z', status: 'matched', missed: true, late_minutes: null, complaints: 1, open_complaints: 1, sla_breached: true, complaint_kinds: 'no_show' }], 'Live 2026-11-19 10:00 UTC')
  assert.match(ex.split('\r\n')[1], /^September 2026,Live 2026-11-19 10:00 UTC,E,V,S,2026-09-03T10:00:00Z,matched,Yes,,1,1,Yes,no_show$/)
  assert.equal(packFileName('pack', 'Soft FM One!', '2026-09-01', true), 'duly-sla-pack-soft-fm-one-2026-09-frozen.csv')
  assert.equal(packFileName('pack', 'Soft FM One!', '2026-09-01', false), 'duly-sla-pack-soft-fm-one-2026-09-live.csv')
  assert.equal(csvBasis('2026-10-03T02:15:00+00:00'), 'Frozen 2026-10-03')
  assert.equal(csvBasis(null, new Date('2026-11-19T10:07:45Z')), 'Live 2026-11-19 10:07 UTC')
  assert.equal(packFileName('visits', '???', '2026-09-01', true), 'duly-sla-visits-enterprise-2026-09-frozen.csv')
})

test('a claim document is checked, named and stored safely', async () => {
  const { checkClaimFile, safeFileName, claimFilePath, claimFileLabel, claimFileType, CLAIM_FILE_MAX_BYTES } = await import('./claimEvidence.ts')
  assert.equal(checkClaimFile({ name: 'cert.pdf', size: 1000, type: 'application/pdf' }), null)
  assert.equal(checkClaimFile({ name: 'scan.JPG', size: 1000, type: 'image/jpeg' }), null)
  assert.equal(checkClaimFile({ name: 'photo.heic', size: 1000, type: '' }), null, 'a browser that gives no type for .heic is judged by the extension')
  assert.match(checkClaimFile({ name: 'a.pdf', size: 0, type: 'application/pdf' }) ?? '', /empty/)
  assert.match(checkClaimFile({ name: 'a.pdf', size: CLAIM_FILE_MAX_BYTES + 1, type: 'application/pdf' }) ?? '', /10 MB/)
  assert.match(checkClaimFile({ name: 'a.svg', size: 10, type: 'image/svg+xml' }) ?? '', /PDF or a photo/)
  assert.match(checkClaimFile({ name: 'a.html', size: 10, type: 'text/html' }) ?? '', /PDF or a photo/)
  assert.match(checkClaimFile({ name: 'noext', size: 10, type: '' }) ?? '', /PDF or a photo/)
  assert.equal(claimFileType({ name: 'x.PNG', type: '' }), 'image/png')
  assert.equal(safeFileName('Public Liability (2026).PDF'), 'public-liability-2026.pdf')
  assert.equal(safeFileName('../../etc/passwd'), 'passwd', 'folders are dropped')
  assert.equal(safeFileName('C:\\Users\\me\\cert.pdf'), 'cert.pdf')
  assert.equal(safeFileName('=cmd|calc.pdf'), 'cmd-calc.pdf')
  assert.equal(safeFileName('.pdf'), 'pdf', 'a dotfile name is not an extension')
  assert.equal(safeFileName('###.png'), 'document.png')
  assert.ok(safeFileName('a'.repeat(200) + '.pdf').length <= 65)
  const p = claimFilePath('org-1', 'claim-1', 'My Cert.pdf', 1700000000000)
  assert.equal(p, 'org-1/claim-1/1700000000000-my-cert.pdf')
  assert.equal(p.split('/').length, 3, 'always three parts: vendor, claim, file')
  assert.equal(claimFileLabel(p), 'my-cert.pdf')
  assert.equal(claimFileLabel(null), '')
})
