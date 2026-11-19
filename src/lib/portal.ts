// Which console a person belongs in, and what its menu holds. Pure, so it can be tested.
//
// Duly has one console per kind of person: Admin (Duly staff), Enterprise, Pro (a cleaning vendor), the Client site view and the older buyer app.
// Pages several kinds of person share (a visit, a brief, notifications, account) should open inside the console of whoever is looking, with
// that console's menu, so following a link never drops someone out of their own portal.

export type NavItem = { label: string; to: string; exact?: boolean; feature?: 'shifts' }
export type PortalKind = 'admin' | 'enterprise' | 'pro' | 'client' | 'buyer'

export const ENTERPRISE_NAV: NavItem[] = [
  { label: 'Overview', to: '/enterprise', exact: true },
  { label: 'Delivery', to: '/enterprise/delivery' },
  { label: 'Reports', to: '/enterprise/reports' },
  { label: 'Vendors', to: '/enterprise/vendors' },
  { label: 'Sites and clients', to: '/enterprise/sites' },
]

export const PRO_NAV: NavItem[] = [
  { label: 'Today', to: '/pro', exact: true },
  { label: 'Quote requests', to: '/pro/quotes' },
  { label: 'Dispatch', to: '/pro/dispatch' },
  { label: 'Jobs and crew', to: '/pro/jobs' },
  { label: 'Performance', to: '/pro/performance' },
  { label: 'Shifts', to: '/pro/shifts', feature: 'shifts' },
  { label: 'Profile and rates', to: '/pro/profile' },
  { label: 'Verification', to: '/pro/verification' },
  { label: 'Payouts', to: '/pro/payouts' },
  { label: 'Team', to: '/pro/team' },
]

export const ADMIN_NAV: NavItem[] = [
  { label: 'Overview', to: '/admin', exact: true },
  { label: 'Verification', to: '/admin/verification' },
  { label: 'Case files', to: '/admin/cases' },
  { label: 'Operations', to: '/admin/operations' },
  { label: 'Issues', to: '/admin/issues' },
  { label: 'Payments ledger', to: '/admin/payments' },
  { label: 'Workers and DBS', to: '/admin/workers', feature: 'shifts' },
  { label: 'Enterprises', to: '/admin/enterprises' },
  { label: 'Organisations and people', to: '/admin/people' },
  { label: 'Markets and policies', to: '/admin/policies' },
  { label: 'Data retention', to: '/admin/retention' },
  { label: 'Feature switches', to: '/admin/features' },
]

/** The menu without the items behind a switch that is off. */
export function visibleNav(items: NavItem[], features: { shifts: boolean }): NavItem[] {
  return items.filter((n) => !n.feature || features[n.feature])
}

const VENDOR_STAFF = ['vendor_admin', 'dispatcher']
const BUYER_ROLES = ['owner', 'approver', 'viewer']

/** Which console chrome a shared page uses for this person. No roles at all means a Client with access to a site. */
export function portalFor(roles: string[], isEnterpriseMember: boolean): PortalKind {
  if (roles.includes('platform_admin')) return 'admin'
  if (isEnterpriseMember) return 'enterprise'
  if (roles.some((r) => VENDOR_STAFF.includes(r))) return 'pro'
  if (roles.length === 0) return 'client'
  return 'buyer'
}

/** Where someone signed in at the front door belongs, or null when the front page itself is their home (a homeowner or business buyer). */
export function homeFor(p: { roles: string[]; isEnterpriseMember: boolean; hasWorkerRecord: boolean; siteCount: number }): string | null {
  if (p.roles.includes('platform_admin')) return '/admin'
  if (p.isEnterpriseMember) return '/enterprise'
  if (p.roles.some((r) => VENDOR_STAFF.includes(r))) return '/pro'
  if (p.roles.some((r) => BUYER_ROLES.includes(r))) return null
  if (p.roles.includes('operative') || p.hasWorkerRecord) return '/crew'
  if (p.roles.length === 0 && p.siteCount > 0) return '/client'
  return null
}

/** The menu item the person is on, so a small screen can name it: the longest item whose path the page sits under. */
export function activeNav(items: NavItem[], pathname: string): NavItem | null {
  let best: NavItem | null = null
  for (const n of items) {
    const here = n.exact ? pathname === n.to : pathname === n.to || pathname.startsWith(n.to + '/')
    if (here && (!best || n.to.length > best.to.length)) best = n
  }
  return best
}
