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
  const { ready, session, memberships, hasWorkerRecord, loadFailed, refresh, signOut } = useAuth()

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
  // We could not look up who this is (usually no signal). Don't call that "no access" or offer to sign them up.
  if (loadFailed && memberships.length === 0 && !hasWorkerRecord) {
    return (
      <div className="card mx-auto my-12 max-w-sm p-6">
        <h2 className="text-2xl">We couldn't load your account</h2>
        <p className="mt-2 text-ink-2">Check your signal and try again. Nothing has changed on your account.</p>
        <button className="btn btn-primary mt-4" onClick={() => void refresh()}>
          Try again
        </button>
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
