import { Link, createFileRoute } from '@tanstack/react-router'
import { useEffect, useState } from 'react'
import { Empty } from '#/components/Shells'
import { Badge, ErrorNote, Loading, Section } from '#/components/ui'
import type { Database } from '#/lib/database.types'
import { ATTENTION_LABEL, DELIVERY_RANGES, deliveryCounts, deliveryDates, deliveryText, openFor } from '#/lib/delivery'
import type { DeliveryRange } from '#/lib/delivery'
import { groupByDay } from '#/lib/dispatch'
import { label, must, useLoad, when } from '#/lib/format'
import { minutesText, pct } from '#/lib/measures'
import { supabase } from '#/lib/supabase'
import { useEnterprise } from '#/lib/useEnterprise'

export const Route = createFileRoute('/enterprise/delivery')({ component: EnterpriseDelivery })

type Visit = Database['public']['Functions']['enterprise_delivery_board']['Returns'][number]

const dayName = (iso: string) => new Date(iso).toLocaleDateString('en-GB', { weekday: 'long', day: 'numeric', month: 'long' })
const clock = (iso: string) => new Date(iso).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })

function EnterpriseDelivery() {
  const enterprise = useEnterprise()!
  const [range, setRange] = useState<DeliveryRange>('last7')
  const [updated, setUpdated] = useState<Date | null>(null)
  const [busy, setBusy] = useState<string | null>(null)
  const [actionError, setActionError] = useState<string | null>(null)
  const { data, error, reload } = useLoad(async () => {
    const db = supabase()
    const { from, to } = deliveryDates(range)
    const [board, vendors, issues] = await Promise.all([
      db.rpc('enterprise_delivery_board', { p_enterprise: enterprise.id, p_from: from, p_to: to }),
      db.rpc('enterprise_vendor_delivery', { p_enterprise: enterprise.id, p_from: from, p_to: to }),
      db.rpc('enterprise_open_issues', { p_enterprise: enterprise.id }),
    ])
    setUpdated(new Date())
    return { board: must(board), vendors: must(vendors), issues: must(issues) }
  }, [enterprise.id, range])

  // A live view: look again every minute.
  useEffect(() => {
    const t = setInterval(reload, 60000)
    return () => clearInterval(t)
  }, [reload])

  async function escalate(issueId: string) {
    setBusy(issueId)
    setActionError(null)
    const { error: err } = await supabase().rpc('enterprise_escalate_issue', { p_issue: issueId })
    setBusy(null)
    if (err) return setActionError(err.message)
    reload()
  }

  if (error && !data) return <ErrorNote message={error} />
  if (!data) return <Loading />

  // The database puts what needs attention first, most urgent first; keep its order.
  const needs = data.board.filter((v) => v.attention)
  const rest = data.board.filter((v) => !v.attention)
  const counts = deliveryCounts(data.board)

  return (
    <div className="space-y-8">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p className="text-sm font-medium text-primary">{enterprise.name}</p>
          <h1 className="mt-1 text-3xl">Delivery</h1>
          <p className="mt-1 max-w-2xl text-sm text-ink-2">
            Every vendor's visits at your sites. Missed, late and unstaffed visits come first, so you see them before a client has to complain. It looks again every minute.
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <div className="flex flex-wrap gap-1" role="group" aria-label="Period">
            {DELIVERY_RANGES.map((r) => (
              <button key={r.key} className={`btn text-sm ${range === r.key ? 'btn-primary' : 'btn-ghost'}`} aria-pressed={range === r.key} onClick={() => setRange(r.key)}>
                {r.text}
              </button>
            ))}
          </div>
          <button className="btn btn-ghost text-sm" onClick={reload}>
            Refresh
          </button>
        </div>
      </div>
      {updated && <p className="-mt-6 text-xs text-ink-2">Updated {clock(updated.toISOString())}</p>}
      <ErrorNote message={error ?? actionError} />

      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Tile label="Needs a vendor's attention" value={counts.problems} watch={counts.problems > 0} note={summary(counts)} />
        <Tile label="Waiting for your check" value={counts.awaiting_check} note="Finished by the cleaner" />
        <Tile label="Open problems" value={data.issues.length} watch={data.issues.some((i) => i.breached)} note={`${data.issues.filter((i) => i.breached).length} past their response time`} />
        <Tile label="Visits in this period" value={data.board.length} />
      </div>

      {data.vendors.length === 0 ? (
        <Empty title="No vendors on your roster yet">Duly adds your vendors during onboarding. You then accept each one under Vendors.</Empty>
      ) : (
        <Section title="How each vendor is delivering">
          <p className="text-sm text-ink-2">Visits scheduled in this period. A visit is evidenced when the cleaner checked in, ticked every planned area and took a photo.</p>
          <div className="grid gap-3 md:grid-cols-2">
            {data.vendors.map((v) => (
              <div key={v.vendor_org_id} className="card space-y-3 p-4">
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <p className="font-semibold">{v.vendor_name}</p>
                  {v.roster_status !== 'active' && <Badge value={v.roster_status === 'suspended' ? 'rejected' : 'awaiting'}>{label(v.roster_status)}</Badge>}
                </div>
                <dl className="grid grid-cols-2 gap-x-4 gap-y-2 text-sm">
                  <Figure term="Evidenced" value={pct(v.evidenced_rate)} note={`${v.evidenced_visits} of ${v.due_visits} due`} />
                  <Figure term="On time" value={pct(v.on_time_rate)} note={`${v.on_time_visits} of ${v.checked_in_visits} arrived`} />
                  <Figure term="Late" value={String(v.late_visits)} watch={v.late_visits > 0} />
                  <Figure term="Missed" value={String(v.missed_visits)} watch={v.missed_visits > 0} />
                  <Figure term="Complaints" value={String(v.complaints)} note={`${v.open_issues} open`} watch={v.open_issues > 0} />
                  <Figure term="Past response time" value={String(v.sla_breaches)} watch={v.sla_breaches > 0} />
                  <Figure term="Right first time" value={pct(v.first_time_right_rate)} />
                  <Figure term="Waiting for a check" value={String(v.awaiting_check)} note={`${v.upcoming_visits} still to come`} />
                </dl>
              </div>
            ))}
          </div>
        </Section>
      )}

      {data.issues.length > 0 && (
        <Section title="Open problems">
          <p className="text-sm text-ink-2">Past their response time first. {enterprise.canManage ? 'You can hand a problem to Duly if the vendor is not putting it right.' : ''}</p>
          <ul className="space-y-2">
            {data.issues.map((i) => (
              <li key={i.issue_id} className={`card space-y-1 p-4 ${i.breached ? 'border-alert' : ''}`}>
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div>
                    <p className="font-semibold">
                      {label(i.kind)} · {i.vendor_name}
                    </p>
                    <p className="text-sm text-ink-2">
                      {i.site_name} · visit {when(i.scheduled_start)}
                      {i.plan_label ? ` · ${i.plan_label}` : ''}
                    </p>
                  </div>
                  <div className="flex flex-wrap items-center gap-2">
                    {i.breached && <Badge value="expired">Past response time</Badge>}
                    <Badge value={i.status}>{i.status === 'mediation' ? 'With Duly' : label(i.status)}</Badge>
                    <Link to="/jobs/$jobId" params={{ jobId: i.job_id }} className="link-action text-sm font-semibold text-primary">
                      Open visit
                    </Link>
                  </div>
                </div>
                <p className="text-sm">{i.description}</p>
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <p className="text-xs text-ink-2">
                    Open for {openFor(i.hours_open)}
                    {i.sla_due_at ? ` · response due ${when(i.sla_due_at)}` : ''}
                  </p>
                  {enterprise.canManage && i.status !== 'mediation' && (
                    <button className="btn btn-ghost text-sm" disabled={busy === i.issue_id} onClick={() => void escalate(i.issue_id)}>
                      Hand to Duly
                    </button>
                  )}
                </div>
              </li>
            ))}
          </ul>
        </Section>
      )}

      {data.board.length === 0 ? (
        <Empty title="No visits in this period">When an Enterprise site's quote is accepted, its visits appear here.</Empty>
      ) : (
        <div className="space-y-8">
          {needs.length > 0 && (
            <Section title="Needs attention now">
              <div className="space-y-2">
                {needs.map((v) => (
                  <VisitCard key={v.job_id} v={v} />
                ))}
              </div>
            </Section>
          )}
          {groupByDay(rest, dayName).map((g, i) => (
            <Section key={g.day + i} title={g.day}>
              <div className="space-y-2">
                {g.rows.map((v) => (
                  <VisitCard key={v.job_id} v={v} />
                ))}
              </div>
            </Section>
          ))}
        </div>
      )}
    </div>
  )
}

function summary(c: ReturnType<typeof deliveryCounts>): string {
  const parts = [
    c.missed && `${c.missed} missed`,
    c.late && `${c.late} late`,
    c.no_crew && `${c.no_crew} with nobody assigned`,
    c.overrunning && `${c.overrunning} overrunning`,
    c.held && `${c.held} held by a complaint`,
  ].filter(Boolean)
  return parts.length ? parts.join(' · ') : 'Everything is covered'
}

function Tile({ label: text, value, note, watch }: { label: string; value: number; note?: string; watch?: boolean }) {
  return (
    <div className={`card p-4 ${watch ? 'border-alert' : ''}`}>
      <p className="text-sm text-ink-2">{text}</p>
      <p className="mt-1 font-display text-3xl">{value}</p>
      {note && <p className={`mt-1 text-xs ${watch ? 'text-alert' : 'text-ink-2'}`}>{note}</p>}
    </div>
  )
}

function Figure({ term, value, note, watch }: { term: string; value: string; note?: string; watch?: boolean }) {
  return (
    <div>
      <dt className="text-ink-2">{term}</dt>
      <dd className={`font-semibold ${watch ? 'text-alert' : ''}`}>{value}</dd>
      {note && <dd className="text-xs text-ink-2">{note}</dd>}
    </div>
  )
}

function VisitCard({ v }: { v: Visit }) {
  return (
    <div className={`card space-y-1 p-4 ${v.attention && v.attention !== 'awaiting_check' ? 'border-alert' : ''}`}>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p className="font-semibold">
            {when(v.scheduled_start)} – {clock(v.scheduled_end)}
            {v.is_rework && <span className="ml-2 text-sm font-medium text-alert">Rework visit</span>}
          </p>
          <p className="text-sm text-ink-2">
            {v.vendor_name} · {v.site_name}
            {v.town ? `, ${v.town}` : ''} · {minutesText(v.planned_minutes)} planned
            {v.is_rework && v.rework_area ? ` · ${v.rework_area}` : ''}
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-3">
          {v.attention && <Badge value={v.attention === 'awaiting_check' ? 'submitted' : 'expired'}>{ATTENTION_LABEL[v.attention as keyof typeof ATTENTION_LABEL] ?? v.attention}</Badge>}
          <Badge value={v.status} />
          <Link to="/jobs/$jobId" params={{ jobId: v.job_id }} className="link-action text-sm font-semibold text-primary">
            Open visit
          </Link>
        </div>
      </div>
      {v.attention && <p className={`text-sm font-medium ${v.attention === 'awaiting_check' ? '' : 'text-alert'}`}>{deliveryText(v)}</p>}
      <p className="text-xs text-ink-2">
        {v.crew_count} cleaner{v.crew_count === 1 ? '' : 's'}
        {v.checked_in_at ? ` · arrived ${clock(v.checked_in_at)}` : ''}
        {v.planned_areas ? ` · ${v.ticked_areas ?? 0} of ${v.planned_areas} areas ticked` : ''}
        {v.photos ? ` · ${v.photos} photo${v.photos === 1 ? '' : 's'}` : ''}
        {v.open_issues ? ` · ${v.open_issues} open problem${v.open_issues === 1 ? '' : 's'}` : ''}
      </p>
    </div>
  )
}
