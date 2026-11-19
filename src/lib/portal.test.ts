import assert from 'node:assert/strict'
import { test } from 'node:test'
import { ADMIN_NAV, ENTERPRISE_NAV, PRO_NAV, activeNav, homeFor, portalFor, visibleNav } from './portal.ts'

test('a shared page opens in the console of whoever is looking', () => {
  assert.equal(portalFor(['platform_admin'], false), 'admin')
  assert.equal(portalFor(['platform_admin', 'owner'], true), 'admin', 'Duly staff come first')
  assert.equal(portalFor(['owner'], true), 'enterprise')
  assert.equal(portalFor(['viewer'], true), 'enterprise')
  assert.equal(portalFor(['vendor_admin'], false), 'pro')
  assert.equal(portalFor(['dispatcher'], false), 'pro')
  assert.equal(portalFor(['owner'], false), 'buyer', 'a homeowner or business buyer keeps the buyer app')
  assert.equal(portalFor(['operative'], false), 'buyer')
  assert.equal(portalFor([], false), 'client', 'no roles means a Client with access to a site')
})

test('the front door sends each kind of person to their own home', () => {
  const base = { roles: [] as string[], isEnterpriseMember: false, hasWorkerRecord: false, siteCount: 0 }
  assert.equal(homeFor({ ...base, roles: ['platform_admin'] }), '/admin')
  assert.equal(homeFor({ ...base, roles: ['owner'], isEnterpriseMember: true }), '/enterprise')
  assert.equal(homeFor({ ...base, roles: ['vendor_admin'] }), '/pro')
  assert.equal(homeFor({ ...base, roles: ['dispatcher'] }), '/pro')
  assert.equal(homeFor({ ...base, roles: ['operative'] }), '/crew')
  assert.equal(homeFor({ ...base, hasWorkerRecord: true }), '/crew')
  assert.equal(homeFor({ ...base, siteCount: 2 }), '/client')
  assert.equal(homeFor({ ...base, roles: ['owner'] }), null, 'a buyer stays on the front page')
  assert.equal(homeFor({ ...base, roles: ['owner', 'operative'] }), null, 'a buyer who also works as crew is still a buyer here')
  assert.equal(homeFor(base), null, 'someone with nothing yet stays on the front page')
  assert.equal(homeFor({ ...base, roles: ['vendor_admin', 'owner'] }), '/pro', 'vendor staff go to Pro')
})

test('the menus hide what a switch has turned off, and name the page you are on', () => {
  assert.ok(PRO_NAV.some((n) => n.to === '/pro/shifts') && !visibleNav(PRO_NAV, { shifts: false }).some((n) => n.to === '/pro/shifts'))
  assert.ok(visibleNav(PRO_NAV, { shifts: true }).some((n) => n.to === '/pro/shifts'))
  assert.ok(!visibleNav(ADMIN_NAV, { shifts: false }).some((n) => n.to === '/admin/workers'))
  assert.equal(visibleNav(ENTERPRISE_NAV, { shifts: false }).length, ENTERPRISE_NAV.length)
  for (const nav of [ENTERPRISE_NAV, PRO_NAV, ADMIN_NAV]) assert.equal(new Set(nav.map((n) => n.to)).size, nav.length, 'no page listed twice')
  assert.equal(activeNav(ENTERPRISE_NAV, '/enterprise')?.label, 'Overview')
  assert.equal(activeNav(ENTERPRISE_NAV, '/enterprise/delivery')?.label, 'Delivery')
  assert.equal(activeNav(ENTERPRISE_NAV, '/enterprise/sites/abc')?.label, 'Sites and clients')
  assert.equal(activeNav(ENTERPRISE_NAV, '/enterprise/vendorsx'), null, 'a path that merely starts the same is not a match')
  assert.equal(activeNav(ENTERPRISE_NAV, '/jobs/123'), null, 'a shared page matches no menu item')
  assert.equal(activeNav(PRO_NAV, '/pro')?.label, 'Today')
  assert.equal(activeNav(PRO_NAV, '/pro/schedules/q1'), null, 'a nested page with no menu item of its own matches nothing, not Today')
})
