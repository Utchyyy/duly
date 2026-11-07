import { Link, createFileRoute } from '@tanstack/react-router'
import { useState } from 'react'
import { Badge, ErrorNote, Loading } from '#/components/ui'
import type { Database } from '#/lib/database.types'
import { label, must, useLoad, when } from '#/lib/format'
import { supabase } from '#/lib/supabase'

export const Route = createFileRoute('/admin/issues')({ component: AdminIssues })

type Status = Database['public']['Enums']['issue_status']
const statuses: Status[] = ['open', 'vendor_fix', 'partial_refund', 'mediation', 'resolved']

function AdminIssues() {
  const [showResolved, setShowResolved] = useState(false)
  const { data, error, reload } = useLoad(async () => {
    let q = supabase()
      .from('issues')
      .select('id, kind, description, status, resolution, sla_due_at, created_at, job_id, job:jobs(scheduled_start, vendor:organisations!jobs_vendor_org_id_fkey(name), site:sites(name, town))')
      .order('created_at', { ascending: false })
    if (!showResolved) q = q.neq('status', 'resolved')
    return must(await q)
  }, [showResolved])

  if (error) return <ErrorNote message={error} />
  if (!data) return <Loading />

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-3xl">Issues</h1>
        <label className="flex min-h-[44px] items-center gap-2 text-sm">
          <input type="checkbox" className="size-5" checked={showResolved} onChange={(e) => setShowResolved(e.target.checked)} />
          Show resolved
        </label>
      </div>
      <p className="text-sm text-ink-2">An open issue holds the job's money. Resolving the last one returns the job to the client's review, or lets money be released if it was already approved.</p>
      {data.length === 0 && <p className="text-ink-2">Nothing open.</p>}
      {data.map((i) => (
        <IssueCard key={i.id} issue={i} onChange={reload} />
      ))}
    </div>
  )
}

type IssueRow = {
  id: string
  kind: string
  description: string
  status: Status
  resolution: string | null
  sla_due_at: string | null
  created_at: string
  job_id: string | null
  job: { scheduled_start: string; vendor: { name: string } | null; site: { name: string; town: string | null } | null } | null
}

function IssueCard({ issue, onChange }: { issue: IssueRow; onChange: () => void }) {
  const [status, setStatus] = useState<Status>(issue.status)
  const [resolution, setResolution] = useState(issue.resolution ?? '')
  const [error, setError] = useState<string | null>(null)
  const overdue = issue.status !== 'resolved' && issue.sla_due_at && new Date(issue.sla_due_at) < new Date()

  async function save() {
    setError(null)
    const { error: err } = await supabase().from('issues').update({ status, resolution: resolution.trim() || null }).eq('id', issue.id)
    if (err) setError(err.message)
    onChange()
  }

  return (
    <div className={`card space-y-3 p-4 ${issue.kind === 'safeguarding' ? 'border-alert' : ''}`}>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p className="font-semibold">
            {label(issue.kind)}
            {issue.kind === 'safeguarding' && <span className="ml-2 text-xs text-alert">Private: only you and the reporter see this</span>}
          </p>
          <p className="text-sm text-ink-2">
            {issue.job?.vendor?.name} · {issue.job?.site?.name}, {issue.job?.site?.town} · clean {when(issue.job?.scheduled_start)} · reported {when(issue.created_at)}
          </p>
        </div>
        <div className="flex items-center gap-2">
          {overdue && <Badge value="expired">Response overdue</Badge>}
          <Badge value={issue.status} />
        </div>
      </div>
      <p className="text-sm">{issue.description}</p>
      {issue.job_id && (
        <Link to="/jobs/$jobId" params={{ jobId: issue.job_id }} className="text-sm font-semibold text-primary">
          Open the job and evidence
        </Link>
      )}
      <div className="flex flex-wrap gap-2">
        <select className="field w-auto" value={status} onChange={(e) => setStatus(e.target.value as Status)} aria-label="Status">
          {statuses.map((s) => (
            <option key={s} value={s}>
              {label(s)}
            </option>
          ))}
        </select>
        <input className="field min-w-[14rem] flex-1" placeholder="Outcome (shown to the client and vendor)" value={resolution} onChange={(e) => setResolution(e.target.value)} />
        <button className="btn btn-primary" onClick={() => void save()}>
          Save
        </button>
      </div>
      <ErrorNote message={error} />
    </div>
  )
}
