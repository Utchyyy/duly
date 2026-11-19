import { Link, createFileRoute, useNavigate } from '@tanstack/react-router'
import { useEffect } from 'react'
import { BuyerHome } from '#/components/BuyerHome'
import { AppShell } from '#/components/Shells'
import { SignIn } from '#/components/SignIn'
import { useAuth } from '#/lib/auth'
import { must, useLoad } from '#/lib/format'
import { homeFor } from '#/lib/portal'
import { supabase } from '#/lib/supabase'
import { useEnterprise } from '#/lib/useEnterprise'

export const Route = createFileRoute('/')({ component: BuyerPage })

/** Everyone signed in at the front door goes to their own console; only a homeowner or business buyer stays on this page. */
function SignedIn() {
  const { memberships, session, hasWorkerRecord } = useAuth()
  const enterprise = useEnterprise()
  const navigate = useNavigate()
  const userId = session?.user.id ?? ''
  const roles = memberships.map((m) => m.role)
  // A person with no organisation and no worker record may be a Client with a login for a site: look.
  const mayBeClient = roles.length === 0 && !hasWorkerRecord
  const { data: sites } = useLoad(async () => {
    if (!mayBeClient) return 0
    return must(await supabase().from('site_access').select('id').eq('user_id', userId)).length
  }, [userId, mayBeClient])

  const target = homeFor({ roles, isEnterpriseMember: enterprise !== null, hasWorkerRecord, siteCount: sites ?? 0 })
  useEffect(() => {
    if (target) void navigate({ to: target, replace: true })
  }, [target, navigate])

  if (target || (mayBeClient && sites === undefined)) return <p className="py-6 text-ink-2">Loading…</p>
  return <BuyerHome mode="home" />
}

const ENTRANCES = [
  { to: '/enterprise', title: 'Duly Enterprise', text: 'You manage cleaning vendors across sites. See every visit, check the evidence and run your monthly report.' },
  { to: '/pro', title: 'Duly Pro', text: 'You run a cleaning company. Dispatch crews, send work schedules and keep the record of every clean.' },
  { to: '/client', title: 'Your sites', text: 'You work at a site an Enterprise manages. See who cleaned it, when, and the photos.' },
] as const

function BuyerPage() {
  const { ready, session } = useAuth()

  if (ready && session) {
    return (
      <AppShell>
        <SignedIn />
      </AppShell>
    )
  }
  return (
    <AppShell wide>
      <div className="space-y-10">
        <div className="grid gap-8 md:grid-cols-[minmax(0,1fr)_24rem] md:items-start">
          <section className="pt-2 md:pt-8">
            <h1 className="text-4xl leading-tight md:text-5xl">One record of every clean.</h1>
            <p className="mt-3 max-w-xl text-lg text-ink-2">
              Duly shows an enterprise, its cleaning vendors and the people at each site which vendor cleaned which site, when, to what standard, and with
              what evidence.
            </p>
          </section>
          <SignIn allowSignUp heading="Sign in" />
        </div>
        <section aria-labelledby="entrances">
          <h2 id="entrances" className="text-xl">
            Where do you work?
          </h2>
          <ul className="mt-3 grid gap-3 md:grid-cols-3">
            {ENTRANCES.map((e) => (
              <li key={e.to}>
                <Link to={e.to} className="card flex h-full min-h-[44px] flex-col gap-1 p-4 hover:border-primary">
                  <span className="font-display text-lg font-semibold text-primary">{e.title}</span>
                  <span className="text-sm text-ink-2">{e.text}</span>
                </Link>
              </li>
            ))}
          </ul>
        </section>
      </div>
    </AppShell>
  )
}
