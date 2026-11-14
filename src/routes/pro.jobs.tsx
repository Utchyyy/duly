import { Link, createFileRoute } from '@tanstack/react-router'
import { useState } from 'react'
import { AssignCrew } from '#/components/AssignCrew'
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
    const [jobs, members, contracts, problems] = await Promise.all([
      db
        .from('jobs')
        .select('id, status, scheduled_start, value, currency, rework_of_issue, site:sites(name, town, postcode, access_notes), job_assignments(user_id, role)')
        .eq('vendor_org_id', vendor.id)
        .gte('scheduled_start', since)
        .order('scheduled_start'),
      db.rpc('org_member_emails', { p_org: vendor.id }),
      db
        .from('contracts')
        .select('id, billing, starts_on, brief_id, brief_version, buyer:organisations!contracts_buyer_org_id_fkey(name), site:sites(name, town)')
        .eq('vendor_org_id', vendor.id)
        .eq('status', 'active')
        .order('created_at', { ascending: false }),
      // Problems clients have reported on this vendor's cleans that are not yet resolved (never safeguarding reports: only Duly sees those).
      db
        .from('issues')
        .select('id, job_id, kind, description, status, resolution, plan_label, created_at, job:jobs!issues_job_id_fkey!inner(vendor_org_id, scheduled_start, site:sites(name, town))')
        .eq('job.vendor_org_id', vendor.id)
        .neq('status', 'resolved')
        .order('created_at', { ascending: false }),
    ])
    const problemRows = must(problems)
    const ids = problemRows.map((p) => p.id)
    const reworks = ids.length ? must(await db.from('jobs').select('id, status, scheduled_start, rework_of_issue').in('rework_of_issue', ids)) : []
    return { jobs: must(jobs), members: must(members) as Member[], contracts: must(contracts), problems: problemRows, reworks }
  }, [vendor.id])

  if (error) return <ErrorNote message={error} />
  if (!data) return <Loading />

  const upcoming = data.jobs.filter((j) => ['matched', 'en_route', 'on_site', 'in_progress', 'requested'].includes(j.status))
  const done = data.jobs.filter((j) => !upcoming.includes(j))

  return (
    <div className="space-y-8">
      <h1 className="text-3xl">Jobs and crew</h1>
      {data.problems.length > 0 && (
        <Section title="Problems to put right">
          <div className="space-y-2">
            {data.problems.map((p) => (
              <div key={p.id} className="card space-y-1 border-alert p-4 text-sm">
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <p className="font-semibold">
                    {label(p.kind)} · clean {when(p.job?.scheduled_start)} · {p.job?.site?.name}
                  </p>
                  <Badge value={p.status} />
                </div>
                {p.plan_label && <p className="font-medium">About: {p.plan_label}</p>}
                <p>{p.description}</p>
                {p.resolution && <p className="text-ink-2">Outcome so far: {p.resolution}</p>}
                <Rework problem={p} reworks={data.reworks.filter((r) => r.rework_of_issue === p.id)} onChange={reload} />
                <Link to="/crew/$jobId" params={{ jobId: p.job_id ?? '' }} className="link-action text-sm font-semibold text-primary">
                  Job sheet
                </Link>
              </div>
            ))}
          </div>
        </Section>
      )}
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
      {data.contracts.length > 0 && (
        <Section title="Clients">
          <div className="space-y-2">
            {data.contracts.map((c) => (
              <ContractRow key={c.id} contract={c} onChange={reload} />
            ))}
          </div>
        </Section>
      )}
      {done.length > 0 && (
        <Section title="Last two weeks">
          <div className="space-y-2">
            {done.map((j) => (
              <div key={j.id} className="card flex flex-wrap items-center justify-between gap-3 p-4">
                <div>
                  <p className="font-semibold">
                    {when(j.scheduled_start)}
                    {j.rework_of_issue && <span className="ml-2 text-sm font-medium text-alert">Rework visit</span>}
                  </p>
                  <p className="text-sm text-ink-2">
                    {j.site?.name}, {j.site?.town} · {j.rework_of_issue ? 'No charge' : money(j.value, j.currency)}
                  </p>
                </div>
                <div className="flex items-center gap-3">
                  <Badge value={j.status} />
                  <Link to="/crew/$jobId" params={{ jobId: j.id }} className="link-action text-sm font-semibold text-primary">
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
  rework_of_issue: string | null
  scheduled_start: string
  value: number | null
  currency: string
  site: { name: string; town: string | null; postcode: string | null; access_notes: string | null } | null
  job_assignments: { user_id: string; role: string }[]
}

function JobCard({ job, members, onChange }: { job: JobRow; members: Member[]; onChange: () => void }) {
  return (
    <div className="card space-y-3 p-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p className="font-semibold">
            {when(job.scheduled_start)}
            {job.rework_of_issue && <span className="ml-2 text-sm font-medium text-alert">Rework visit</span>}
          </p>
          <p className="text-sm text-ink-2">
            {job.site?.name}, {job.site?.town} {job.site?.postcode} · {job.rework_of_issue ? 'No charge: putting a reported problem right' : money(job.value, job.currency)}
          </p>
          {job.site?.access_notes && <p className="mt-1 text-sm">Access: {job.site.access_notes}</p>}
        </div>
        <div className="flex items-center gap-3">
          <Badge value={job.status} />
          <Link to="/crew/$jobId" params={{ jobId: job.id }} className="link-action text-sm font-semibold text-primary">
            Job sheet
          </Link>
        </div>
      </div>
      <AssignCrew jobId={job.id} assigned={job.job_assignments} members={members} onChange={onChange} />
    </div>
  )
}

type ContractData = {
  id: string
  billing: string
  starts_on: string | null
  buyer: { name: string } | null
  site: { name: string; town: string | null } | null
}

function ContractRow({ contract, onChange }: { contract: ContractData; onChange: () => void }) {
  const [msg, setMsg] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  async function book() {
    setError(null)
    setMsg(null)
    const { data, error: err } = await supabase().rpc('schedule_visits', { p_contract: contract.id, p_weeks: 4 })
    if (err) return setError(err.message)
    setMsg(data === 0 ? 'Already booked for the next four weeks.' : `Booked ${data} visit(s).`)
    onChange()
  }
  return (
    <div className="card space-y-2 p-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <p className="font-semibold">{contract.buyer?.name}</p>
          <p className="text-sm text-ink-2">
            {contract.site?.name}, {contract.site?.town} · {contract.billing === 'monthly' ? 'Monthly plan' : 'Per clean'}
          </p>
        </div>
        <button className="btn btn-ghost text-sm" onClick={() => void book()}>
          Book the next 4 weeks
        </button>
      </div>
      {msg && <p className="text-sm text-primary">{msg}</p>}
      <ErrorNote message={error} />
    </div>
  )
}

type Problem = { id: string; kind: string; status: string; plan_label: string | null }
type ReworkRow = { id: string; status: string; scheduled_start: string }

/** A reported problem that names a cleaning area can be put right on a booked rework visit. */
function Rework({ problem, reworks, onChange }: { problem: Problem; reworks: ReworkRow[]; onChange: () => void }) {
  const [start, setStart] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const active = reworks.filter((r) => !['cancelled', 'disputed'].includes(r.status))
  const eligible = problem.plan_label && ['quality', 'access', 'no_show', 'other'].includes(problem.kind) && ['open', 'vendor_fix'].includes(problem.status)

  async function book() {
    setBusy(true)
    setError(null)
    const { error: err } = await supabase().rpc('book_rework', { p_issue: problem.id, p_start: new Date(start).toISOString() })
    setBusy(false)
    if (err) return setError(err.message)
    setStart('')
    onChange()
  }

  if (active.length > 0) {
    return (
      <div className="rounded-lg bg-tint p-3">
        {active.map((r) => (
          <p key={r.id}>
            Rework visit {when(r.scheduled_start)} · <Badge value={r.status} />{' '}
            <Link to="/crew/$jobId" params={{ jobId: r.id }} className="link-action font-semibold text-primary">
              Job sheet
            </Link>
          </p>
        ))}
        <p className="mt-1 text-xs text-ink-2">Assign a cleaner under Coming up. The client accepts the area once it is done, which closes the problem.</p>
      </div>
    )
  }
  if (problem.status === 'mediation') return <p className="rounded-lg bg-line/50 p-3">Duly is looking at this: the rework was not accepted.</p>
  if (!eligible) return null
  return (
    <div className="space-y-2 rounded-lg bg-tint p-3">
      <p className="font-medium">Put it right: book a rework visit for {problem.plan_label}</p>
      <div className="flex flex-wrap items-end gap-2">
        <label className="text-xs text-ink-2">
          When
          <input type="datetime-local" className="field mt-1 block w-auto" value={start} onChange={(e) => setStart(e.target.value)} />
        </label>
        <button className="btn btn-primary" disabled={busy || !start} onClick={() => void book()}>
          Book rework visit
        </button>
      </div>
      <ErrorNote message={error} />
    </div>
  )
}
