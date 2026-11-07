import { useAuth } from './auth'

/** The vendor organisation the signed-in person works for (first one, if several). */
export function useVendor() {
  const { memberships } = useAuth()
  const m = memberships.find((x) => x.org?.kind === 'vendor' && (x.role === 'vendor_admin' || x.role === 'dispatcher'))
  return m?.org ? { id: m.org.id, name: m.org.name, isAdmin: m.role === 'vendor_admin' } : null
}
