import { Link, createFileRoute } from '@tanstack/react-router'
import { useState } from 'react'
import { PhotoStrip, useSignedUrls } from '#/components/Evidence'
import { WorkPlanView } from '#/components/WorkPlan'
import type { EvidenceRow } from '#/components/Evidence'
import { Badge, ErrorNote, Loading, Section, Table } from '#/components/ui'
import type { Json } from '#/lib/database.types'
import { label, money, must, useLoad } from '#/lib/format'
import { parseSchedule, totalMinutes } from '#/lib/schedule'
import { supabase } from '#/lib/supabase'
import {
  DAY_FULL,
  METHOD_LABEL,
  parseLegend,
  parsePlan,
  workForDay,
} from '#/lib/workplan'
import type { Day } from '#/lib/workplan'

export const Route = createFileRoute('/admin/cases/$briefId')({
  component: CaseFile,
})

/** Evidence needs exact times, with the year and seconds: not the friendly short form used elsewhere. */
function stamp(iso: string | null | undefined): string {
  if (!iso) return '–'
  return new Date(iso).toLocaleString('en-GB', {
    day: 'numeric',
    month: 'short',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    timeZoneName: 'short',
  })
}

async function loadCase(briefId: string) {
  const db = supabase()
  const brief = must(
    await db
      .from('briefs')
      .select(
        'id, title, status, current_version, created_at, buyer:organisations!briefs_buyer_org_id_fkey(id, name, segment), site:sites(name, address_line1, town, postcode, geofence_m)',
      )
      .eq('id', briefId)
      .single(),
  )
  const [versions, quotes, contracts, jobs, timeline, schedules] =
    await Promise.all([
      db
        .from('brief_versions')
        .select(
          'version, schedule, notes, preferred_days, preferred_start, locked_at, locked_by, created_at',
        )
        .eq('brief_id', briefId)
        .order('version'),
      db
        .from('quotes')
        .select(
          'id, status, brief_version, total, currency, lines, urgency, valid_until, submitted_at, created_at, vendor:organisations(id, name)',
        )
        .eq('brief_id', briefId)
        .order('created_at'),
      db
        .from('contracts')
        .select(
          'id, status, brief_version, billing, monthly_value, currency, payment_terms_days, sla_response_hours, created_at, vendor:organisations!contracts_vendor_org_id_fkey(name)',
        )
        .eq('brief_id', briefId),
      db
        .from('jobs')
        .select(
          'id, status, brief_version, quote_id, scheduled_start, scheduled_end, value, currency, created_at, vendor:organisations!jobs_vendor_org_id_fkey(name)',
        )
        .eq('brief_id', briefId)
        .order('scheduled_start'),
      db.rpc('admin_case_timeline', { p_brief: briefId, p_limit: 5000 }),
      db
        .from('work_schedules')
        .select(
          'id, quote_id, status, plan, legend, submitted_at, locked_at, vendor:organisations(name)',
        )
        .eq('brief_id', briefId)
        .order('created_at'),
    ])
  const jobRows = must(jobs)
  const jobIds = jobRows.map((j) => j.id)
  const contractRows = must(contracts)
  const none = ['00000000-0000-0000-0000-000000000000']
  const [evidence, results, issues, payments, checkIns, planResults, planDays] =
    await Promise.all([
      db
        .from('evidence')
        .select(
          'id, job_id, area_id, kind, storage_path, within_geofence, taken_at, created_at, lat, lng',
        )
        .in('job_id', jobIds.length ? jobIds : none)
        .order('created_at'),
      db
        .from('area_results')
        .select(
          'job_id, area_id, standard_id, done_by_operative, done_at, verdict, verdict_at',
        )
        .in('job_id', jobIds.length ? jobIds : none),
      db
        .from('issues')
        .select(
          'id, job_id, kind, description, status, resolution, created_at, resolved_at, sla_due_at, plan_label',
        )
        .in('job_id', jobIds.length ? jobIds : none)
        .order('created_at'),
      db
        .from('payments')
        .select(
          'id, job_id, contract_id, kind, amount, currency, status, provider, provider_ref, due_at, paid_at, note, created_at',
        )
        .or(
          `job_id.in.(${(jobIds.length ? jobIds : none).join(',')}),contract_id.in.(${(contractRows.length ? contractRows.map((c) => c.id) : none).join(',')})`,
        )
        .order('created_at'),
      db
        .from('job_events')
        .select('job_id, kind, at, lat, lng, within_geofence')
        .in('job_id', jobIds.length ? jobIds : none)
        .eq('kind', 'check_in'),
      db
        .from('plan_results')
        .select('job_id, plan_item_id, done, done_at, verdict, verdict_at')
        .in('job_id', jobIds.length ? jobIds : none),
      // The weekday of each visit when the work schedule decided the check (null: the brief's standards did).
      Promise.all(
        jobIds.map(async (id) => {
          const r = await db.rpc('job_plan_day', { p_job: id })
          return [id, r.error ? null : (r.data as string | null)] as const
        }),
      ),
    ])
  return {
    brief,
    versions: must(versions),
    quotes: must(quotes),
    contracts: contractRows,
    jobs: jobRows,
    timeline: must(timeline),
    schedules: must(schedules),
    planResults: must(planResults),
    planDays: Object.fromEntries(planDays) as Record<string, string | null>,
    evidence: must(evidence) as (EvidenceRow & {
      job_id: string
      taken_at: string | null
      lat: number | null
      lng: number | null
    })[],
    results: must(results),
    issues: must(issues),
    payments: must(payments),
    checkIns: must(checkIns),
  }
}
type CaseData = Awaited<ReturnType<typeof loadCase>>

function CaseFile() {
  const { briefId } = Route.useParams()
  const { data, error } = useLoad(() => loadCase(briefId), [briefId])
  const urls = useSignedUrls(data?.evidence)

  if (error) return <ErrorNote message={error} />
  if (!data) return <Loading />
  const { brief } = data

  return (
    <div className="space-y-8">
      <div className="flex flex-wrap items-start justify-between gap-3 print:hidden">
        <Link
          to="/admin/cases"
          className="link-action text-sm font-medium text-primary"
        >
          ← All case files
        </Link>
        <button className="btn btn-ghost" onClick={() => window.print()}>
          Print or save as PDF
        </button>
      </div>

      <div>
        <h1 className="text-3xl">{brief.title}</h1>
        <p className="mt-1 text-sm text-ink-2">
          Client {brief.buyer?.name} · {brief.site?.name},{' '}
          {brief.site?.address_line1 ? `${brief.site.address_line1}, ` : ''}
          {brief.site?.town} {brief.site?.postcode} · on-site radius{' '}
          {brief.site?.geofence_m ?? '–'} m
        </p>
        <p className="text-sm text-ink-2">
          Brief created {stamp(brief.created_at)} ·{' '}
          <Badge value={brief.status} />
        </p>
        <p className="mt-2 text-xs text-ink-2">
          Case file generated {stamp(new Date().toISOString())}. Times are
          exact. The timeline below is an append-only record: no one, including
          Duly, can change or remove an entry.
        </p>
      </div>

      <Section title="What was asked (the brief as agreed)">
        {data.versions.map((v) => {
          const schedule = parseSchedule(v.schedule)
          return (
            <div key={v.version} className="card space-y-2 p-4">
              <p className="font-semibold">
                Version {v.version}{' '}
                <span className="text-sm font-normal text-ink-2">
                  {v.locked_at
                    ? `locked ${stamp(v.locked_at)}`
                    : 'never locked (still a draft)'}{' '}
                  · {totalMinutes(schedule)} minutes per visit
                  {v.preferred_days?.length
                    ? ` · ${v.preferred_days.join(', ')}`
                    : ''}
                  {v.preferred_start
                    ? ` at ${v.preferred_start.slice(0, 5)}`
                    : ''}
                </span>
              </p>
              {schedule.map((s) => (
                <div key={s.name}>
                  <p className="text-sm font-medium">{s.name}</p>
                  <ul className="ml-4 list-disc text-sm text-ink-2">
                    {s.areas.map((a) => (
                      <li key={a.id}>
                        {a.name}, {a.minutes} min
                        <ul className="ml-4 list-[circle]">
                          {a.standards.map((st) => (
                            <li key={st.id}>{st.text}</li>
                          ))}
                        </ul>
                      </li>
                    ))}
                  </ul>
                </div>
              ))}
              {v.notes && <p className="text-sm">Notes: {v.notes}</p>}
            </div>
          )
        })}
      </Section>

      <Section title="Vendors invited and what they quoted">
        {data.quotes.length === 0 ? (
          <p className="text-ink-2">No vendor has been invited yet.</p>
        ) : (
          <Table
            head={[
              'Vendor',
              'Status',
              'Invited',
              'Submitted',
              'Total',
              'Brief version',
            ]}
          >
            {data.quotes.map((q) => (
              <tr
                key={q.id}
                className="border-b border-line last:border-0 align-top"
              >
                <td className="p-3 font-medium">{q.vendor?.name}</td>
                <td className="p-3">
                  <Badge value={q.status} />
                </td>
                <td className="p-3 whitespace-nowrap">{stamp(q.created_at)}</td>
                <td className="p-3 whitespace-nowrap">
                  {stamp(q.submitted_at)}
                </td>
                <td className="p-3">
                  {q.total == null ? '–' : money(q.total, q.currency)}
                </td>
                <td className="p-3">{q.brief_version}</td>
              </tr>
            ))}
          </Table>
        )}
        {data.schedules.map((w) => (
          <details key={w.id} className="text-sm">
            <summary className="flex min-h-[44px] cursor-pointer items-center font-medium text-primary">
              Work schedule from {w.vendor?.name} ({w.status}
              {w.submitted_at ? `, sent ${stamp(w.submitted_at)}` : ''}
              {w.locked_at ? `, locked ${stamp(w.locked_at)}` : ''})
            </summary>
            <WorkPlanView
              plan={parsePlan(w.plan)}
              legend={parseLegend(w.legend)}
            />
          </details>
        ))}
        {data.contracts.map((c) => (
          <p key={c.id} className="text-sm text-ink-2">
            Contract with {c.vendor?.name} ({c.status}, created{' '}
            {stamp(c.created_at)}): {label(c.billing)}
            {c.monthly_value != null
              ? ` ${money(c.monthly_value, c.currency)}`
              : ''}
            , payment terms {c.payment_terms_days} days, response within{' '}
            {c.sla_response_hours} h.
          </p>
        ))}
      </Section>

      {data.jobs.map((job) => (
        <JobRecord key={job.id} job={job} data={data} urls={urls} />
      ))}
      {data.jobs.length === 0 && (
        <Section title="Jobs">
          <p className="text-ink-2">No job has been booked from this brief.</p>
        </Section>
      )}

      <Timeline rows={data.timeline} />
    </div>
  )
}

function JobRecord({
  job,
  data,
  urls,
}: {
  job: CaseData['jobs'][number]
  data: CaseData
  urls: Record<string, string>
}) {
  const version = data.versions.find((v) => v.version === job.brief_version)
  const schedule = parseSchedule(version?.schedule as Json | undefined)
  const evidence = data.evidence.filter((e) => e.job_id === job.id)
  const results = data.results.filter((r) => r.job_id === job.id)
  const issues = data.issues.filter((i) => i.job_id === job.id)
  const payments = data.payments.filter((p) => p.job_id === job.id)
  const checkIn = data.checkIns.find((c) => c.job_id === job.id)
  const ws = data.schedules.find(
    (w) => w.quote_id === job.quote_id && w.status === 'locked',
  )
  const plan = ws ? parsePlan(ws.plan) : null
  const planDay = data.planDays[job.id] ?? null

  return (
    <Section title={`Job: ${job.vendor?.name}, ${stamp(job.scheduled_start)}`}>
      <p className="text-sm text-ink-2">
        <Badge value={job.status} /> · scheduled {stamp(job.scheduled_start)} to{' '}
        {stamp(job.scheduled_end)} · value{' '}
        {job.value == null ? '–' : money(job.value, job.currency)} · brief
        version {job.brief_version}
      </p>
      <p className="text-sm">
        {checkIn
          ? `Crew checked in ${stamp(checkIn.at)}, ${checkIn.within_geofence === false ? 'OUTSIDE' : checkIn.within_geofence ? 'inside' : 'location not recorded relative to'} the site radius${
              checkIn.lat != null ? ` (${checkIn.lat}, ${checkIn.lng})` : ''
            }.`
          : 'No check-in has been recorded.'}
      </p>

      {plan && planDay && (
        <>
          <p className="text-sm">
            Checked against the work schedule for {DAY_FULL[planDay as Day]}:
            each cleaning area planned that day, with when the crew ticked it
            and the client's verdict.
          </p>
          {workForDay(plan, planDay as Day).map((g) => {
            const photos = evidence.filter((e) => e.area_id === g.sub.id)
            return (
              <div key={g.sub.id} className="card space-y-2 p-4">
                <p className="font-semibold">
                  {g.section} · {g.sub.name}
                </p>
                <ul className="space-y-1 text-sm">
                  {g.rows.map(({ row, method }) => {
                    const r = data.planResults.find(
                      (x) => x.job_id === job.id && x.plan_item_id === row.id,
                    )
                    return (
                      <li key={row.id}>
                        {row.name} ({METHOD_LABEL[method]})
                        <span className="block text-ink-2">
                          Crew:{' '}
                          {r?.done
                            ? `ticked ${stamp(r.done_at)}`
                            : 'not ticked'}{' '}
                          · Client verdict:{' '}
                          {r?.verdict
                            ? `${label(r.verdict)} ${stamp(r.verdict_at)}`
                            : 'none yet'}
                        </span>
                      </li>
                    )
                  })}
                </ul>
                <PhotoStrip rows={photos} urls={urls} />
                {photos.length > 0 && (
                  <ul className="text-xs text-ink-2">
                    {photos.map((p) => (
                      <li key={p.id}>
                        {p.kind === 'photo_before' ? 'Before' : 'After'}: taken{' '}
                        {p.taken_at ? stamp(p.taken_at) : 'time not recorded'},
                        received {stamp(p.created_at)},{' '}
                        {p.within_geofence === false
                          ? 'off site'
                          : p.within_geofence
                            ? 'on site'
                            : 'location unknown'}
                        {p.lat != null ? ` (${p.lat}, ${p.lng})` : ''}
                      </li>
                    ))}
                  </ul>
                )}
              </div>
            )
          })}
        </>
      )}

      {!(plan && planDay) &&
        schedule
          .flatMap((s) => s.areas)
          .map((area) => {
            const photos = evidence.filter((e) => e.area_id === area.id)
            return (
              <div key={area.id} className="card space-y-2 p-4">
                <p className="font-semibold">{area.name}</p>
                <ul className="space-y-1 text-sm">
                  {area.standards.map((st) => {
                    const r = results.find(
                      (x) => x.area_id === area.id && x.standard_id === st.id,
                    )
                    return (
                      <li key={st.id}>
                        {st.text}
                        <span className="block text-ink-2">
                          Crew:{' '}
                          {r?.done_by_operative
                            ? `ticked ${stamp(r.done_at)}`
                            : 'not ticked'}{' '}
                          · Client verdict:{' '}
                          {r?.verdict
                            ? `${label(r.verdict)} ${stamp(r.verdict_at)}`
                            : 'none yet'}
                        </span>
                      </li>
                    )
                  })}
                </ul>
                <PhotoStrip rows={photos} urls={urls} />
                {photos.length > 0 && (
                  <ul className="text-xs text-ink-2">
                    {photos.map((p) => (
                      <li key={p.id}>
                        {p.kind === 'photo_before' ? 'Before' : 'After'}: taken{' '}
                        {p.taken_at ? stamp(p.taken_at) : 'time not recorded'},
                        received {stamp(p.created_at)},{' '}
                        {p.within_geofence === false
                          ? 'off site'
                          : p.within_geofence
                            ? 'on site'
                            : 'location unknown'}
                        {p.lat != null ? ` (${p.lat}, ${p.lng})` : ''}
                      </li>
                    ))}
                  </ul>
                )}
              </div>
            )
          })}

      {issues.length > 0 && (
        <div className="space-y-2">
          <p className="font-semibold">Issues</p>
          {issues.map((i) => (
            <div key={i.id} className="card space-y-1 p-4 text-sm">
              <p>
                <span className="font-semibold">{label(i.kind)}</span> reported{' '}
                {stamp(i.created_at)} · <Badge value={i.status} />
              </p>
              {i.plan_label && (
                <p className="font-medium">About: {i.plan_label}</p>
              )}
              <p>{i.description}</p>
              <p className="text-ink-2">
                Response due {stamp(i.sla_due_at)}
                {i.resolved_at ? ` · resolved ${stamp(i.resolved_at)}` : ''}
                {i.resolution ? ` · outcome: ${i.resolution}` : ''}
              </p>
            </div>
          ))}
        </div>
      )}

      {payments.length > 0 && (
        <Table
          head={['Payment', 'Amount', 'Status', 'Due', 'Paid', 'Reference']}
        >
          {payments.map((p) => (
            <tr key={p.id} className="border-b border-line last:border-0">
              <td className="p-3">{label(p.kind)}</td>
              <td className="p-3">{money(p.amount, p.currency)}</td>
              <td className="p-3">
                <Badge value={p.status} />
              </td>
              <td className="p-3 whitespace-nowrap">{stamp(p.due_at)}</td>
              <td className="p-3 whitespace-nowrap">{stamp(p.paid_at)}</td>
              <td className="p-3">{p.provider_ref ?? '–'}</td>
            </tr>
          ))}
        </Table>
      )}
    </Section>
  )
}

type TimelineRow = {
  at: string
  kind: string
  table_name: string
  op: string
  summary: string
  changes: Json
  actor_id: string | null
  actor_name: string | null
  actor_email: string | null
  within_geofence: boolean | null
  lat: number | null
  lng: number | null
  source: string
}

function who(r: TimelineRow): string {
  if (!r.actor_id) return r.source === 'backfill' ? 'Not recorded' : 'System'
  return r.actor_name
    ? `${r.actor_name} (${r.actor_email ?? 'no email'})`
    : (r.actor_email ?? 'Unknown person')
}

function Timeline({ rows }: { rows: TimelineRow[] }) {
  const [open, setOpen] = useState<Set<number>>(new Set())
  const [onlyActors, setOnlyActors] = useState(false)
  const shown = onlyActors ? rows.filter((r) => r.actor_id) : rows
  const toggle = (i: number) =>
    setOpen((prev) => {
      const next = new Set(prev)
      if (next.has(i)) next.delete(i)
      else next.add(i)
      return next
    })

  return (
    <Section
      title="Timeline: who did what, and when"
      action={
        <label className="flex min-h-[44px] items-center gap-2 text-sm print:hidden">
          <input
            type="checkbox"
            className="size-5"
            checked={onlyActors}
            onChange={(e) => setOnlyActors(e.target.checked)}
          />
          People only (hide system steps)
        </label>
      }
    >
      <p className="text-sm text-ink-2">
        {rows.length} entries. Entries marked "recorded from the current row"
        were made before the audit log existed, so they show only what the
        record still holds, without who did it or earlier changes.
      </p>
      <ol className="card divide-y divide-line">
        {shown.map((r, i) => {
          const detailed =
            r.changes &&
            typeof r.changes === 'object' &&
            Object.keys(r.changes).length > 0
          return (
            <li key={`${r.at}-${i}`} className="space-y-1 p-3 text-sm">
              <div className="flex flex-wrap items-baseline justify-between gap-2">
                <p className="font-medium">{r.summary}</p>
                <p className="whitespace-nowrap text-xs text-ink-2">
                  {stamp(r.at)}
                </p>
              </div>
              <p className="text-xs text-ink-2">
                {who(r)} · {label(r.table_name)}
                {r.kind === 'job_event' && r.lat != null
                  ? ` · at ${r.lat}, ${r.lng}${r.within_geofence === false ? ' (OUTSIDE the site radius)' : r.within_geofence ? ' (on site)' : ''}`
                  : ''}
              </p>
              {detailed && (
                <>
                  <button
                    className="link-action text-xs text-primary print:hidden"
                    onClick={() => toggle(i)}
                  >
                    {open.has(i) ? 'Hide details' : 'Show what changed'}
                  </button>
                  <pre
                    className={`overflow-x-auto rounded bg-tint/60 p-2 text-xs ${open.has(i) ? '' : 'hidden print:block'}`}
                  >
                    {JSON.stringify(r.changes, null, 2)}
                  </pre>
                </>
              )}
            </li>
          )
        })}
      </ol>
    </Section>
  )
}
