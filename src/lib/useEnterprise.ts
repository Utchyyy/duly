import { useAuth } from './auth'
import { pickEnterprise } from './enterprise'
import type { EnterpriseOrg } from './enterprise'

export function useEnterprise(): EnterpriseOrg | null {
  const { memberships } = useAuth()
  return pickEnterprise(memberships)
}
