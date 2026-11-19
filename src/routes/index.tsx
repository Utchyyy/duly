import { Link, createFileRoute, useNavigate } from '@tanstack/react-router'
import { useEffect } from 'react'
import { BuyerHome } from '#/components/BuyerHome'
import { AppShell } from '#/components/Shells'
import { SignIn } from '#/components/SignIn'
import { useAuth } from '#/lib/auth'
import { must, useLoad } from '#/lib/format'
import { supabase } from '#/lib/supabase'
import { useEnterprise } from '#/lib/useEnterprise'

export const Route = createFileRoute('/')({ component: BuyerPage })

/** An Enterprise's staff go to their portal; a Client with access to a site goes to their sites; everyone else gets the buyer home. */
function SignedIn() {
  const { memberships, session } = useAuth()
  const enterprise = useEnterprise()
  const navigate = useNavigate()
  const userId = session?.user.id ?? ''
  const { data: sites } = useLoad(async () => {
    if (enterprise || memberships.length > 0) return 0
    const r = must(await supabase().from('site_access').select('id').eq('user_id', userId))
    return r.length
  }, [userId, enterprise?.id, memberships.length])

  const toClient = !enterprise && memberships.length === 0 && (sites ?? 0) > 0
  useEffect(() => {
    if (enterprise) void navigate({ to: '/enterprise', replace: true })
    else if (toClient) void navigate({ to: '/client', replace: true })
  }, [enterprise, toClient, navigate])

  if (enterprise || toClient || (!enterprise && memberships.length === 0 && sites === undefined)) return <p className="py-6 text-ink-2">Loading…</p>
  return <BuyerHome mode="home" />
}

function BuyerPage() {
  const { ready, session } = useAuth()

  return (
    <AppShell>
      {ready && session ? (
        <SignedIn />
      ) : (
        <div className="space-y-8">
          <section className="pt-4">
            <h1 className="text-4xl leading-tight">One record of every clean.</h1>
            <p className="mt-3 text-lg text-ink-2">
              Duly shows an enterprise, its cleaning vendors and the people at each site which vendor cleaned which site, when, to what standard,
              and with what evidence.
            </p>
          </section>
          <SignIn allowSignUp heading="Sign in" />
          <p className="text-center text-sm text-ink-2">
            Enterprise?{' '}
            <Link to="/enterprise" className="font-semibold text-primary">
              Duly Enterprise
            </Link>{' '}
            · Cleaning vendor?{' '}
            <Link to="/pro" className="font-semibold text-primary">
              Duly Pro
            </Link>
          </p>
        </div>
      )}
    </AppShell>
  )
}
