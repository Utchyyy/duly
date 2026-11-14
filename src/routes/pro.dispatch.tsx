import { Link, createFileRoute } from '@tanstack/react-router'
import { useEffect, useState } from 'react'
import { AssignCrew } from '#/components/AssignCrew'
import type { CrewMember } from '#/components/AssignCrew'
import { Empty } from '#/components/Shells'
import { Badge, ErrorNote, Loading, Section } from '#/components/ui'
import type { Database } from '#/lib/database.types'
import { attentionCounts, attentionText, boardDates, crewNames, groupByDay } from '#/lib/dispatch'
import type { BoardRange } from '#/lib/dispatch'
import { must, useLoad, when } from '#/lib/format'
import { minutesText } from '#/lib/measures'
import { supabase } from '#/lib/supabase'
import { useVendor } from '#/lib/vendor'

export const Route = createFileRoute('/pro/dispatch')({ component: ProDispatch })

type Visit = Database['public']['Functions']['dispatch_board']['Returns'][number]

const RANGES: { key: BoardRange; text: string }[] = [
  { key: 'today', text: 'Today' },
  { key: '7', text: 'Next 7 days' },
  { key: '14', text: 'Next 14 days' },
]

const dayName = (iso: string) => new Date(iso).toLocaleDateString('en-GB', { weekday: 'long', day: 'numeric', month: 'long' })
const clock = (iso: string) => new Date(iso).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })

function ProDispatch() {
  const vendor = useVendor()!
  const [range, setRange] = useState<BoardRange>('7')
  const [updated, setUpdated] = useState<Date | null>(null)
  const { data, error, reload } = useLoad(async () => {
    const db = supabase()
    const { from, to } = boardDates(range)
    const [board, crew, members] = await Promise.all([
      db.rpc('dispatch_board', { p_vendor: vendor.id, p_from: from, p_to: to }),
      db.rpc('dispatch_crew', { p_vendor: vendor.id, p_from: from, p_to: to }),
      db.rpc('org_member_emails', { p_org: vendor.id }),
    ])
    setUpdated(new Date())
    return { board: must(board), crew: must(crew), members: must(members) as CrewMember[] }
  }, [vendor.id, range])

  // A live board: look again every minute.
  useEffect(() => {
    const t = setInterval(reload, 60000)
    return () => clearInterval(t)
  }, [reload])

  if (error && !data) return <ErrorNote message={error} />
  if (!data) return <Loading />

  // The database puts what needs attention first; keep its order.
  const needs = data.board.filter((v) => v.attention)
  const rest = data.board.filter((v) => !v.attention)
  const counts = attentionCounts(data.board)
  const onVisit = data.crew.filter((c) => c.on_a_visit).length

  return (
    <div className="space-y-8">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-3xl">Dispatch</h1>
          <p className="mt-1 max-w-2xl text-sm text-ink-2">
            Every visit, who is on it, and what needs you now. Late, unstaffed, clashing and overrunning visits come first. It looks again every minute.
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <div className="flex gap-1" role="group" aria-label="Period">
            {RANGES.map((r) => (
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
      <ErrorNote message={error} />

      <div className="grid gap-3 sm:grid-cols-3">
        <Tile label="Needs attention" value={counts.total} watch={counts.total > 0} note={summary(counts)} />
        <Tile label="Visits in this period" value={data.board.length} note={`${data.board.filter((v) => v.awaiting_client).length} waiting for the client to check`} />
        <Tile label="Cleaners on a visit now" value={onVisit} note={`${data.crew.length} on your crew`} />
      </div>

      {data.board.length === 0 ? (
        <Empty title="No visits in this period">When a client accepts a quote, or you book rework visits, they appear here.</Empty>
      ) : (
        <div className="grid gap-8 lg:grid-cols-[minmax(0,1fr)_20rem]">
          <div className="space-y-8">
            {needs.length > 0 && (
              <Section title="Needs attention now">
                <div className="space-y-2">
                  {needs.map((v) => (
                    <VisitCard key={v.job_id} v={v} members={data.members} onChange={reload} />
                  ))}
                </div>
              </Section>
            )}
            {groupByDay(rest, dayName).map((g, i) => (
              <Section key={g.day + i} title={g.day}>
                <div className="space-y-2">
                  {g.rows.map((v) => (
                    <VisitCard key={v.job_id} v={v} members={data.members} onChange={reload} />
                  ))}
                </div>
              </Section>
            ))}
          </div>
          <aside>
            <Section title="Your crew">
              <p className="text-sm text-ink-2">Lightest load first, so the next visit can go to someone with room.</p>
              <ul className="card divide-y divide-line">
                {data.crew.map((c) => (
                  <li key={c.user_id} className="space-y-0.5 p-3 text-sm">
                    <p className="flex items-center justify-between gap-2 font-semibold">
                      {c.name}
                      {c.on_a_visit && <span className="rounded-full bg-tint px-2 py-0.5 text-xs font-semibold text-primary">On a visit</span>}
                    </p>
                    <p className="text-ink-2">
                      {c.visits} visit{c.visits === 1 ? '' : 's'} · {minutesText(c.scheduled_minutes)} booked
                    </p>
                    {c.next_visit && <p className="text-xs text-ink-2">Next: {when(c.next_visit)}</p>}
                  </li>
                ))}
                {data.crew.length === 0 && <li className="p-3 text-sm text-ink-2">No cleaners on your crew yet. Add them under Team.</li>}
              </ul>
            </Section>
          </aside>
        </div>
      )}
    </div>
  )
}

function summary(c: ReturnType<typeof attentionCounts>): string {
  const parts = [
    c.late && `${c.late} late`,
    c.no_crew && `${c.no_crew} with nobody assigned`,
    c.crew_clash && `${c.crew_clash} clashing`,
    c.overrunning && `${c.overrunning} overrunning`,
    c.held && `${c.held} held by a complaint`,
  ].filter(Boolean)
  return parts.length ? parts.join(' · ') : 'Everything is covered'
}

function Tile({ label, value, note, watch }: { label: string; value: number; note?: string; watch?: boolean }) {
  return (
    <div className={`card p-4 ${watch ? 'border-alert' : ''}`}>
      <p className="text-sm text-ink-2">{label}</p>
      <p className="mt-1 font-display text-3xl">{value}</p>
      {note && <p className={`mt-1 text-xs ${watch ? 'text-alert' : 'text-ink-2'}`}>{note}</p>}
    </div>
  )
}

const OPEN = ['requested', 'matched', 'en_route', 'on_site', 'in_progress']

function VisitCard({ v, members, onChange }: { v: Visit; members: CrewMember[]; onChange: () => void }) {
  const crew = crewNames(v.crew)
  const editable = OPEN.includes(v.status)
  return (
    <div className={`card space-y-2 p-4 ${v.attention ? 'border-alert' : ''}`}>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p className="font-semibold">
            {when(v.scheduled_start)} – {clock(v.scheduled_end)}
            {v.is_rework && <span className="ml-2 text-sm font-medium text-alert">Rework visit</span>}
          </p>
          <p className="text-sm text-ink-2">
            {v.site_name}
            {v.town ? `, ${v.town}` : ''} · {minutesText(v.planned_minutes)} planned
            {v.is_rework && v.rework_area ? ` · ${v.rework_area}` : ''}
          </p>
        </div>
        <div className="flex items-center gap-3">
          <Badge value={v.status} />
          <Link to="/crew/$jobId" params={{ jobId: v.job_id }} className="link-action text-sm font-semibold text-primary">
            Job sheet
          </Link>
        </div>
      </div>
      {v.attention && <p className="text-sm font-medium text-alert">{attentionText(v)}</p>}
      {v.attention === 'held' && (
        <p className="text-sm">
          <Link to="/pro/jobs" className="link-action font-semibold text-primary">
            Book a rework visit under Problems to put right
          </Link>
        </p>
      )}
      {editable ? (
        <AssignCrew jobId={v.job_id} assigned={crew.map((c) => ({ user_id: c.user_id, role: c.role }))} members={members} onChange={onChange} quietEmpty={v.attention === 'no_crew'} collapsible startOpen={v.attention === 'no_crew' || v.attention === 'crew_clash'} />
      ) : (
        <p className="text-sm text-ink-2">{crew.length > 0 ? crew.map((c) => c.name).join(', ') : 'No crew recorded'}</p>
      )}
    </div>
  )
}
