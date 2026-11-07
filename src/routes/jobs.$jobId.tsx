import { Link, createFileRoute } from '@tanstack/react-router'
import { useState } from 'react'
import { PhotoStrip, useSignedUrls } from '#/components/Evidence'
import type { EvidenceRow } from '#/components/Evidence'
import { Gate } from '#/components/Gate'
import { AppShell } from '#/components/Shells'
import { Issues } from '#/components/Issues'
import { Badge, ErrorNote, Loading, Section, Table } from '#/components/ui'
import { label, money, must, useLoad, when } from '#/lib/format'
import { parseSchedule } from '#/lib/schedule'
import { supabase } from '#/lib/supabase'

export const Route = createFileRoute('/jobs/$jobId')({
  head: () => ({ meta: [{ title: 'Clean · Duly' }] }),
  component: JobPage,
})

function JobPage() {
  return (
    <AppShell wide>
      <Gate allowSignUp signInHeading="Sign in">
        <Job />
      </Gate>
    </AppShell>
  )
}

function Job() {
  const { jobId } = Route.useParams()
  const { data, error, reload } = useLoad(async () => {
    const db = supabase()
    const job = must(
      await db
        .from('jobs')
        .select(
          'id, status, scheduled_start, scheduled_end, value, currency, brief_id, brief_version, buyer_org_id, vendor:organisations!jobs_vendor_org_id_fkey(name), site:sites(name, town, postcode)',
        )
        .eq('id', jobId)
        .single(),
    )
    const [version, events, evidence, results, payments, issues] = await Promise.all([
      db.from('brief_versions').select('schedule').eq('brief_id', job.brief_id).eq('version', job.brief_version).single(),
      db.from('job_events').select('id, kind, at, within_geofence, data').eq('job_id', jobId).order('at'),
      db.from('evidence').select('id, area_id, kind, storage_path, within_geofence, created_at').eq('job_id', jobId).order('created_at'),
      db.from('area_results').select('area_id, standard_id, done_by_operative, verdict').eq('job_id', jobId),
      db.from('payments').select('id, kind, amount, currency, status, due_at, note').eq('job_id', jobId).order('created_at'),
      db.from('issues').select('id, kind, description, status, resolution, created_at, raised_by').eq('job_id', jobId).order('created_at'),
    ])
    const { data: me } = await db.auth.getUser()
    return {
      job,
      schedule: parseSchedule(must(version).schedule),
      events: must(events),
      evidence: must(evidence) as EvidenceRow[],
      results: must(results),
      payments: must(payments),
      issues: must(issues),
      me: me.user?.id,
    }
  }, [jobId])
  const urls = useSignedUrls(data?.evidence)
  const [busy, setBusy] = useState(false)
  const [actionError, setActionError] = useState<string | null>(null)

  if (error) return <ErrorNote message={error} />
  if (!data) return <Loading />
  const { job } = data
  const reviewing = job.status === 'completed'
  const verdictOf = (area: string, std: string) => data.results.find((r) => r.area_id === area && r.standard_id === std)?.verdict ?? null

  async function setVerdict(area: string, std: string, verdict: 'met' | 'not_met') {
    setActionError(null)
    const { error: err } = await supabase().from('area_results').update({ verdict }).eq('job_id', jobId).eq('area_id', area).eq('standard_id', std)
    if (err) setActionError(err.message)
    reload()
  }

  async function approve() {
    setBusy(true)
    setActionError(null)
    const { error: err } = await supabase().rpc('approve_job', { p_job: jobId })
    setBusy(false)
    if (err) setActionError(err.message)
    reload()
  }

  const allJudged = data.results.length > 0 && data.results.every((r) => r.verdict)
  const anyNotMet = data.results.some((r) => r.verdict === 'not_met')

  return (
    <div className="mx-auto max-w-3xl space-y-8">
      <div>
        <Link to="/" className="text-sm font-medium text-primary">
          ← Back
        </Link>
        <div className="mt-2 flex flex-wrap items-center gap-3">
          <h1 className="text-3xl">{when(job.scheduled_start)}</h1>
          <Badge value={job.status} />
        </div>
        <p className="mt-1 text-ink-2">
          {job.vendor?.name} · {job.site?.name}, {job.site?.town} · {money(job.value, job.currency)}
        </p>
        <Link to="/briefs/$briefId" params={{ briefId: job.brief_id }} className="mt-1 inline-block text-sm font-medium text-primary">
          View the brief (v{job.brief_version})
        </Link>
      </div>

      <Section title="What's happened">
        <ol className="space-y-2 border-l-2 border-line pl-4">
          {data.events.map((e) => (
            <li key={e.id} className="text-sm">
              <span className="font-medium">{eventText(e.kind, e.data)}</span>
              <span className="text-ink-2"> · {when(e.at)}</span>
              {e.within_geofence === false && <span className="ml-2 text-alert">away from the site</span>}
            </li>
          ))}
        </ol>
      </Section>

      {['completed', 'quality_verified', 'paid', 'disputed'].includes(job.status) && (
        <Section title={reviewing ? 'Check the work' : 'The work'}>
          {reviewing && (
            <p className="text-sm text-ink-2">Look at the photos and mark each standard. Money is only released once you approve.</p>
          )}
          {data.schedule.map((s) =>
            s.areas.map((a) => (
              <div key={a.id} className="card space-y-3 p-4">
                <p className="font-semibold">
                  {s.name} · {a.name}
                </p>
                <PhotoStrip rows={data.evidence.filter((e) => e.area_id === a.id)} urls={urls} />
                <ul className="space-y-2">
                  {a.standards.map((st) => {
                    const v = verdictOf(a.id, st.id)
                    return (
                      <li key={st.id} className="flex flex-wrap items-center justify-between gap-2 text-sm">
                        <span>{st.text}</span>
                        {reviewing ? (
                          <span className="flex gap-1">
                            <button
                              className={`btn text-xs ${v === 'met' ? 'btn-primary' : 'btn-ghost'}`}
                              onClick={() => void setVerdict(a.id, st.id, 'met')}
                            >
                              Met
                            </button>
                            <button
                              className={`btn text-xs ${v === 'not_met' ? '!bg-alert text-white' : 'btn-ghost'}`}
                              onClick={() => void setVerdict(a.id, st.id, 'not_met')}
                            >
                              Not met
                            </button>
                          </span>
                        ) : v ? (
                          <Badge value={v} />
                        ) : null}
                      </li>
                    )
                  })}
                </ul>
              </div>
            )),
          )}
          {reviewing && (
            <div className="card space-y-2 p-4">
              <ErrorNote message={actionError} />
              {anyNotMet ? (
                <p className="text-sm text-alert">Some standards weren't met. Report it below so the vendor can come back and put it right.</p>
              ) : (
                <button className="btn btn-primary w-full" disabled={busy || !allJudged} onClick={() => void approve()}>
                  {allJudged ? 'Approve the clean' : 'Mark every standard to approve'}
                </button>
              )}
            </div>
          )}
        </Section>
      )}

      <Issues jobId={jobId} issues={data.issues} me={data.me} onChange={reload} />

      {data.payments.length > 0 && (
        <Section title="Money">
          <Table head={['What', 'Amount', 'Due', 'Status']}>
            {data.payments.map((p) => (
              <tr key={p.id}>
                <td>{p.note ?? label(p.kind)}</td>
                <td>{money(p.amount, p.currency)}</td>
                <td>{when(p.due_at)}</td>
                <td>
                  <Badge value={p.status} />
                </td>
              </tr>
            ))}
          </Table>
        </Section>
      )}
    </div>
  )
}

function eventText(kind: string, data: unknown): string {
  const d = (data ?? {}) as Record<string, unknown>
  switch (kind) {
    case 'check_in':
      return Number(d.late_minutes) > 0 ? `Cleaner arrived (${String(d.late_minutes)} min late)` : 'Cleaner arrived'
    case 'check_out':
      return 'Cleaner finished'
    case 'status_change':
      return label(String(d.to ?? 'updated'))
    case 'robot_handoff':
      return 'Robot assist'
    default:
      return label(kind)
  }
}

