import { Link, createFileRoute } from '@tanstack/react-router'
import { Empty } from '#/components/Shells'
import { Badge, ErrorNote, Loading, Section } from '#/components/ui'
import { useAuth } from '#/lib/auth'
import { must, useLoad, when } from '#/lib/format'
import { supabase } from '#/lib/supabase'

export const Route = createFileRoute('/client/')({ component: ClientHome })

function ClientHome() {
  const { session } = useAuth()
  const userId = session?.user.id ?? ''
  const { data, error } = useLoad(async () => {
    const db = supabase()
    const access = must(await db.from('site_access').select('role, site:sites(id, name, town, postcode)').eq('user_id', userId))
    const ids = access.flatMap((a) => (a.site ? [a.site.id] : []))
    const jobs = ids.length
      ? must(
          await db
            .from('jobs')
            .select('id, status, scheduled_start, site_id, rework_of_issue, vendor:organisations!jobs_vendor_org_id_fkey(name)')
            .in('site_id', ids)
            .neq('status', 'cancelled')
            .order('scheduled_start', { ascending: false })
            .limit(60),
        )
      : []
    return { access, jobs }
  }, [userId])

  if (error) return <ErrorNote message={error} />
  if (!data) return <Loading />
  if (data.access.length === 0) {
    return (
      <Empty title="No sites to show yet">
        Your organisation gives you access to a site. Until then there is nothing here. If you expected to see a site, ask whoever manages your cleaning contract to give {session?.user.email} access.
      </Empty>
    )
  }

  return (
    <div className="space-y-8">
      <div>
        <h1 className="text-3xl">Your sites</h1>
        <p className="mt-1 max-w-2xl text-sm text-ink-2">The record of every clean at your sites: who came, when, what was done, and the photos. Money is not shown here.</p>
      </div>
      {data.access.map((a) => {
        if (!a.site) return null
        const jobs = data.jobs.filter((j) => j.site_id === a.site?.id)
        const toCheck = a.role === 'manager' ? jobs.filter((j) => j.status === 'completed') : []
        return (
          <Section key={a.site.id} title={a.site.name}>
            <p className="-mt-1 text-sm text-ink-2">
              {[a.site.town, a.site.postcode].filter(Boolean).join(' ')} · <span className="font-medium">{a.role === 'manager' ? 'Site manager' : 'Viewer'}</span>
            </p>
            {toCheck.length > 0 && (
              <div className="space-y-2">
                <p className="text-sm font-medium">Waiting for you to check</p>
                {toCheck.map((j) => (
                  <Link key={j.id} to="/jobs/$jobId" params={{ jobId: j.id }} className="card flex items-center justify-between gap-3 border-primary p-4">
                    <div>
                      <p className="font-semibold">{when(j.scheduled_start)}</p>
                      <p className="text-sm text-ink-2">{j.vendor?.name}</p>
                    </div>
                    <Badge value="completed">Check the work</Badge>
                  </Link>
                ))}
              </div>
            )}
            {jobs.length === 0 ? (
              <Empty title="No visits yet">Visits appear here once your vendor is booked at this site.</Empty>
            ) : (
              <ul className="space-y-2">
                {jobs.map((j) => (
                  <li key={j.id}>
                    <Link to="/jobs/$jobId" params={{ jobId: j.id }} className="card flex items-center justify-between gap-3 p-4">
                      <div>
                        <p className="font-semibold">
                          {when(j.scheduled_start)}
                          {j.rework_of_issue && <span className="ml-2 text-sm font-medium text-alert">Putting a problem right</span>}
                        </p>
                        <p className="text-sm text-ink-2">{j.vendor?.name}</p>
                      </div>
                      <Badge value={j.status} />
                    </Link>
                  </li>
                ))}
              </ul>
            )}
          </Section>
        )
      })}
    </div>
  )
}
