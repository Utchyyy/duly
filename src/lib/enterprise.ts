// Which organisation is a person's Enterprise: a buyer organisation in the enterprise segment. Pure, so it can be tested.
type MembershipLike = { org_id: string; role: string; org: { id: string; name: string; kind: string; segment: string | null } | null }

export type EnterpriseOrg = { id: string; name: string; canManage: boolean }

/** `canManage` is the owner or an approver. */
export function pickEnterprise(memberships: MembershipLike[]): EnterpriseOrg | null {
  const m = memberships.find((x) => x.org?.kind === 'buyer' && x.org.segment === 'enterprise')
  if (!m?.org) return null
  return { id: m.org.id, name: m.org.name, canManage: memberships.some((x) => x.org_id === m.org_id && (x.role === 'owner' || x.role === 'approver')) }
}
