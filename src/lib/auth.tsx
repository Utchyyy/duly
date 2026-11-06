import { createContext, useCallback, useContext, useEffect, useState } from 'react'
import type { ReactNode } from 'react'
import type { Session } from '@supabase/supabase-js'
import type { Database } from './database.types'
import { supabase } from './supabase'

export type Role = Database['public']['Enums']['member_role']
export type OrgKind = Database['public']['Enums']['org_kind']

export type Membership = {
  org_id: string
  role: Role
  org: { id: string; name: string; kind: OrgKind; segment: string | null } | null
}

type AuthState = {
  ready: boolean
  session: Session | null
  memberships: Membership[]
  hasWorkerRecord: boolean
  refresh: () => Promise<void>
  signOut: () => Promise<void>
}

const AuthContext = createContext<AuthState | null>(null)

export function AuthProvider({ children }: { children: ReactNode }) {
  const [ready, setReady] = useState(false)
  const [session, setSession] = useState<Session | null>(null)
  const [memberships, setMemberships] = useState<Membership[]>([])
  const [hasWorkerRecord, setHasWorkerRecord] = useState(false)

  const load = useCallback(async (s: Session | null) => {
    setSession(s)
    if (!s) {
      setMemberships([])
      setHasWorkerRecord(false)
      setReady(true)
      return
    }
    const db = supabase()
    const [m, w] = await Promise.all([
      db
        .from('memberships')
        .select('org_id, role, org:organisations(id, name, kind, segment)')
        .eq('user_id', s.user.id),
      db.from('workers').select('id').eq('user_id', s.user.id).maybeSingle(),
    ])
    setMemberships(m.data ?? [])
    setHasWorkerRecord(Boolean(w.data))
    setReady(true)
  }, [])

  useEffect(() => {
    const db = supabase()
    db.auth.getSession().then(({ data }) => load(data.session))
    const { data: sub } = db.auth.onAuthStateChange((_event, s) => {
      void load(s)
    })
    return () => sub.subscription.unsubscribe()
  }, [load])

  const refresh = useCallback(async () => {
    const { data } = await supabase().auth.getSession()
    await load(data.session)
  }, [load])

  const signOut = useCallback(async () => {
    await supabase().auth.signOut()
  }, [])

  return (
    <AuthContext.Provider value={{ ready, session, memberships, hasWorkerRecord, refresh, signOut }}>
      {children}
    </AuthContext.Provider>
  )
}

export function useAuth(): AuthState {
  const ctx = useContext(AuthContext)
  if (!ctx) throw new Error('useAuth must be used inside AuthProvider')
  return ctx
}

export function hasRole(memberships: Membership[], roles: Role[]): boolean {
  return memberships.some((m) => roles.includes(m.role))
}
