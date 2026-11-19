import { Link, createFileRoute } from '@tanstack/react-router'
import { Empty, Stat } from '#/components/Shells'
import { Badge, ErrorNote, Loading, Section, Table } from '#/components/ui'
import { claimsToReview } from '#/lib/compliance'
import { must, useLoad, when } from '#/lib/format'
import { supabase } from '#/lib/supabase'
import { useEnterprise } from '#/lib/useEnterprise'

export const Route = createFileRoute('/enterprise/')({ component: EnterpriseOverview })

function EnterpriseOverview() {
  const enterprise = useEnterprise()!
  const { data, error } = useLoad(async () => {
    const db = supabase()
    const [jobs, roster, sites, problems, compliance] = await Promise.all([
      db
        .from('jobs')
        .select('id, status, scheduled_start, rework_of_issue, site:sites(name, town), vendor:organisations!jobs_vendor_org_id_fkey(name)')
        .eq('buyer_org_id', enterprise.id)
        .order('scheduled_start', { ascending: false })
        .limit(60),
      db.from('enterprise_vendors').select('status').eq('enterprise_org_id', enterprise.id),
      db.from('sites').select('id', { count: 'exact', head: true }).eq('org_id', enterprise.id),
      db.from('issues').select('id, job:jobs!issues_job_id_fkey!inner(buyer_org_id)', { count: 'exact', head: true }).eq('job.buyer_org_id', enterprise.id).neq('status', 'resolved'),
      db.rpc('enterprise_vendor_compliance', { p_enterprise: enterprise.id }),
    ])
    return { jobs: must(jobs), roster: must(roster), sites: sites.count ?? 0, problems: problems.count ?? 0, claimsToReview: claimsToReview(must(compliance)) }
  }, [enterprise.id])

  if (error) return <ErrorNote message={error} />
  if (!data) return <Loading />

  const now = Date.now()
  const week = now + 7 * 86400000
  const upcoming = data.jobs.filter((j) => j.status !== 'cancelled' && new Date(j.scheduled_start).getTime() >= now && new Date(j.scheduled_start).getTime() <= week).length
  const toCheck = data.jobs.filter((j) => j.status === 'completed')
  const activeVendors = data.roster.filter((r) => r.status === 'active').length

  return (
    <div className="space-y-8">
      <div>
        <p className="text-sm font-medium text-primary">{enterprise.name}</p>
        <h1 className="mt-1 text-3xl">Overview</h1>
        <p className="mt-1 max-w-2xl text-sm text-ink-2">Every visit your vendors deliver at your sites, with the evidence behind it.</p>
      </div>

      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Stat label="Active vendors" value={activeVendors} note={`${data.roster.length} on your roster`} />
        <Stat label="Sites" value={data.sites} />
        <Stat label="Visits in the next 7 days" value={upcoming} />
        <Stat label="Waiting for a check" value={toCheck.length} note={`${data.problems} open problem${data.problems === 1 ? '' : 's'}`} />
      </div>

      {data.roster.length === 0 && (
        <Empty title="No vendors on your roster yet">Duly adds your vendors during onboarding. You then accept each one under Vendors before you can appoint it.</Empty>
      )}

      {data.claimsToReview > 0 && (
        <div className="card flex flex-wrap items-center justify-between gap-3 p-4 text-sm">
          <p>
            <span className="font-semibold">{data.claimsToReview} vendor claim{data.claimsToReview === 1 ? '' : 's'}</span> waiting for your review.
          </p>
          <Link to="/enterprise/vendors" className="link-action font-medium text-primary">
            Review evidence
          </Link>
        </div>
      )}

      {toCheck.length > 0 && (
        <Section title="Waiting for a check">
          <p className="text-sm text-ink-2">The cleaner has finished. Look at the photos, then accept each area or report a problem.</p>
          <ul className="space-y-2">
            {toCheck.map((j) => (
              <li key={j.id}>
                <Link to="/jobs/$jobId" params={{ jobId: j.id }} className="card flex items-center justify-between gap-3 border-primary p-4">
                  <div>
                    <p className="font-semibold">{when(j.scheduled_start)}</p>
                    <p className="text-sm text-ink-2">
                      {j.vendor?.name} · {j.site?.name}
                      {j.site?.town ? `, ${j.site.town}` : ''}
                    </p>
                  </div>
                  <Badge value="completed">Check the work</Badge>
                </Link>
              </li>
            ))}
          </ul>
        </Section>
      )}

      <Section title="Visits">
        {data.jobs.length === 0 ? (
          <Empty title="No visits yet">Write a specification for a site, appoint a vendor from your roster, and accept their schedule. The visits appear here.</Empty>
        ) : (
          <Table head={['When', 'Site', 'Vendor', 'Status', '']}>
            {data.jobs.map((j) => (
              <tr key={j.id}>
                <td>
                  {when(j.scheduled_start)}
                  {j.rework_of_issue && <span className="ml-2 text-xs font-medium text-alert">Rework</span>}
                </td>
                <td>
                  {j.site?.name}
                  {j.site?.town ? `, ${j.site.town}` : ''}
                </td>
                <td>{j.vendor?.name}</td>
                <td>
                  <Badge value={j.status} />
                </td>
                <td>
                  <Link to="/jobs/$jobId" params={{ jobId: j.id }} className="link-action text-sm font-semibold text-primary">
                    Open
                  </Link>
                </td>
              </tr>
            ))}
          </Table>
        )}
      </Section>
    </div>
  )
}
