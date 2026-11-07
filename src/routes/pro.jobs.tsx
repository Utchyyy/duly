import { Link, createFileRoute } from '@tanstack/react-router'
import { useState } from 'react'
import { Empty } from '#/components/Shells'
import { Badge, ErrorNote, Loading, Section } from '#/components/ui'
import { label, money, must, useLoad, when } from '#/lib/format'
import { supabase } from '#/lib/supabase'
import { useVendor } from '#/lib/vendor'

export const Route = createFileRoute('/pro/jobs')({ component: ProJobs })

type Member = { user_id: string; email: string; full_name: string | null; role: string }

function ProJobs() {
  const vendor = useVendor()!
  const { data, error, reload } = useLoad(async () => {
    const db = supabase()
    const since = new Date(Date.now() - 14 * 86400000).toISOString()
    const [jobs, members] = await Promise.all([
      db
        .from('jobs')
        .select('id, status, scheduled_start, value, currency, site:sites(name, town, postcode, access_notes), job_assignments(user_id, role)')
        .eq('vendor_org_id', vendor.id)
        .gte('scheduled_start', since)
        .order('scheduled_start'),
      db.rpc('org_member_emails', { p_org: vendor.id }),
    ])
    return { jobs: must(jobs), members: must(members) as Member[] }
  }, [vendor.id])

  if (error) return <ErrorNote message={error} />
  if (!data) return <Loading />

  const upcoming = data.jobs.filter((j) => ['matched', 'en_route', 'on_site', 'in_progress', 'requested'].includes(j.status))
  const done = data.jobs.filter((j) => !upcoming.includes(j))

  return (
    <div className="space-y-8">
      <h1 className="text-3xl">Jobs and crew</h1>
      <Section title="Coming up and in progress">
        {upcoming.length === 0 ? (
          <Empty title="No jobs booked">When a client accepts your quote, the job appears here for you to assign a cleaner.</Empty>
        ) : (
          <div className="space-y-3">
            {upcoming.map((j) => (
              <JobCard key={j.id} job={j} members={data.members} onChange={reload} />
            ))}
          </div>
        )}
      </Section>
      {done.length > 0 && (
        <Section title="Last two weeks">
          <div className="space-y-2">
            {done.map((j) => (
              <div key={j.id} className="card flex flex-wrap items-center justify-between gap-3 p-4">
                <div>
                  <p className="font-semibold">{when(j.scheduled_start)}</p>
                  <p className="text-sm text-ink-2">
                    {j.site?.name}, {j.site?.town} · {money(j.value, j.currency)}
                  </p>
                </div>
                <div className="flex items-center gap-3">
                  <Badge value={j.status} />
                  <Link to="/crew/$jobId" params={{ jobId: j.id }} className="text-sm font-semibold text-primary">
                    Job sheet
                  </Link>
                </div>
              </div>
            ))}
          </div>
        </Section>
      )}
    </div>
  )
}

type JobRow = {
  id: string
  status: string
  scheduled_start: string
  value: number | null
  currency: string
  site: { name: string; town: string | null; postcode: string | null; access_notes: string | null } | null
  job_assignments: { user_id: string; role: string }[]
}

function JobCard({ job, members, onChange }: { job: JobRow; members: Member[]; onChange: () => void }) {
  const [pick, setPick] = useState('')
  const [error, setError] = useState<string | null>(null)
  const name = (id: string) => {
    const m = members.find((x) => x.user_id === id)
    return m ? m.full_name || m.email : 'Unknown'
  }
  const assigned = new Set(job.job_assignments.map((a) => a.user_id))
  const people = Array.from(new Map(members.map((m) => [m.user_id, m])).values()).filter((m) => !assigned.has(m.user_id))

  async function assign() {
    if (!pick) return
    setError(null)
    const { error: err } = await supabase()
      .from('job_assignments')
      .insert({ job_id: job.id, user_id: pick, role: job.job_assignments.length === 0 ? 'lead' : 'crew' })
    if (err) setError(err.message)
    setPick('')
    onChange()
  }

  async function unassign(userId: string) {
    const { error: err } = await supabase().from('job_assignments').delete().eq('job_id', job.id).eq('user_id', userId)
    if (err) setError(err.message)
    onChange()
  }

  return (
    <div className="card space-y-3 p-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p className="font-semibold">{when(job.scheduled_start)}</p>
          <p className="text-sm text-ink-2">
            {job.site?.name}, {job.site?.town} {job.site?.postcode} · {money(job.value, job.currency)}
          </p>
          {job.site?.access_notes && <p className="mt-1 text-sm">Access: {job.site.access_notes}</p>}
        </div>
        <div className="flex items-center gap-3">
          <Badge value={job.status} />
          <Link to="/crew/$jobId" params={{ jobId: job.id }} className="text-sm font-semibold text-primary">
            Job sheet
          </Link>
        </div>
      </div>
      <div className="flex flex-wrap gap-2">
        {job.job_assignments.map((a) => (
          <span key={a.user_id} className="inline-flex items-center gap-2 rounded-full bg-tint px-3 py-1 text-sm text-primary">
            {name(a.user_id)} · {label(a.role)}
            <button className="text-xs font-semibold text-alert" onClick={() => void unassign(a.user_id)} aria-label="Remove">
              ✕
            </button>
          </span>
        ))}
        {job.job_assignments.length === 0 && <span className="text-sm text-alert">No cleaner assigned yet</span>}
      </div>
      <div className="flex flex-wrap gap-2">
        <select className="field w-auto min-w-[14rem]" value={pick} onChange={(e) => setPick(e.target.value)} aria-label="Cleaner">
          <option value="">Choose a team member…</option>
          {people.map((m) => (
            <option key={m.user_id} value={m.user_id}>
              {m.full_name || m.email} ({label(m.role)})
            </option>
          ))}
        </select>
        <button className="btn btn-ghost" disabled={!pick} onClick={() => void assign()}>
          Assign
        </button>
      </div>
      <ErrorNote message={error} />
    </div>
  )
}
