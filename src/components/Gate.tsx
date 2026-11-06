import type { ReactNode } from 'react'
import { hasRole, useAuth } from '#/lib/auth'
import type { Role } from '#/lib/auth'
import { SignIn } from './SignIn'

type Props = {
  /** Roles that may enter. Omit to allow any signed-in user. */
  roles?: Role[]
  /** Also let in people with a worker record (Duly Crew). */
  allowWorkers?: boolean
  allowSignUp: boolean
  signInHeading: string
  children: ReactNode
}

export function Gate({ roles, allowWorkers, allowSignUp, signInHeading, children }: Props) {
  const { ready, session, memberships, hasWorkerRecord, signOut } = useAuth()

  if (!ready) {
    return <p className="p-8 text-center text-ink-2">Loading…</p>
  }
  if (!session) {
    return (
      <div className="px-4 py-12">
        <SignIn allowSignUp={allowSignUp} heading={signInHeading} />
      </div>
    )
  }
  const allowed =
    !roles || hasRole(memberships, roles) || (allowWorkers && hasWorkerRecord) || hasRole(memberships, ['platform_admin'])
  if (!allowed) {
    return (
      <div className="card mx-auto my-12 max-w-sm p-6">
        <h2 className="text-2xl">No access here yet</h2>
        <p className="mt-2 text-ink-2">
          {session.user.email} isn't set up for this area. Ask your administrator to add you.
        </p>
        <button className="btn btn-ghost mt-4" onClick={() => void signOut()}>
          Sign out
        </button>
      </div>
    )
  }
  return <>{children}</>
}
