import { Link, createFileRoute } from '@tanstack/react-router'
import { useState } from 'react'
import { Empty } from '#/components/Shells'
import { ErrorNote, Loading, Section, Table } from '#/components/ui'
import { must, useLoad, when } from '#/lib/format'
import { minutesText, pct, rangeDates, timeAgainstPlan, visitNotes } from '#/lib/measures'
import type { RangeKey } from '#/lib/measures'
import { supabase } from '#/lib/supabase'
import { useVendor } from '#/lib/vendor'

export const Route = createFileRoute('/pro/performance')({ component: ProPerformance })

function Tile({ label, value, note, watch }: { label: string; value: string; note?: string; watch?: boolean }) {
  return (
    <div className={`card p-4 ${watch ? 'border-alert' : ''}`}>
      <p className="text-sm text-ink-2">{label}</p>
      <p className="mt-1 font-display text-3xl">{value}</p>
      {note && <p className={`mt-1 text-xs ${watch ? 'text-alert' : 'text-ink-2'}`}>{note}</p>}
    </div>
  )
}

function ProPerformance() {
  const vendor = useVendor()!
  const [range, setRange] = useState<RangeKey>('30')
  const { data, error } = useLoad(async () => {
    const db = supabase()
    const { from, to } = rangeDates(Number(range))
    const [summary, visits, areas, score] = await Promise.all([
      db.rpc('vendor_operations', { p_vendor: vendor.id, p_from: from, p_to: to }),
      db.rpc('vendor_visits', { p_vendor: vendor.id, p_from: from, p_to: to }),
      db.rpc('vendor_problem_areas', { p_vendor: vendor.id, p_from: from, p_to: to }),
      db.from('vendor_scores').select('quality_score, jobs_completed').eq('org_id', vendor.id).maybeSingle(),
    ])
    return { summary: must(summary)[0], visits: must(visits), areas: must(areas), score: score.error ? (() => { throw new Error(score.error.message) })() : score.data }
  }, [vendor.id, range])

  if (error) return <ErrorNote message={error} />
  if (!data) return <Loading />
  const s = data.summary
  const plan = timeAgainstPlan(s?.time_vs_plan)

  return (
    <div className="space-y-8">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-3xl">Performance</h1>
          <p className="mt-1 max-w-2xl text-sm text-ink-2">
            How your visits went against the plan. Everything here is worked out from check-ins, ticks, photos and what clients reported, so it is the same record your clients and Duly see.
          </p>
        </div>
        <div className="flex gap-1" role="group" aria-label="Period">
          {(['30', '90'] as const).map((k) => (
            <button key={k} className={`btn text-sm ${range === k ? 'btn-primary' : 'btn-ghost'}`} aria-pressed={range === k} onClick={() => setRange(k)}>
              Last {k} days
            </button>
          ))}
        </div>
      </div>

      {!s || s.visits === 0 ? (
        <Empty title="No visits in this period yet">Once a cleaner checks in to a job, how it went against the plan shows up here.</Empty>
      ) : (
        <>
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            <Tile
              label="Your Duly score"
              value={data.score?.quality_score == null ? '–' : String(Math.round(data.score.quality_score))}
              note="Out of 100, over all your visits. It is built from the measures below, and it is what clients' lists are ordered by."
            />
            <Tile label="Visits checked in" value={String(s.visits)} />
            <Tile label="On time" value={pct(s.on_time_rate)} note={s.avg_late_minutes ? `Average ${Math.round(s.avg_late_minutes)} min after the start time` : 'Arrived by the start time'} watch={s.on_time_rate != null && s.on_time_rate < 0.9} />
            <Tile label="Planned areas ticked" value={pct(s.plan_followed_rate)} note="Of the cleaning areas the plan called for" watch={s.plan_followed_rate != null && s.plan_followed_rate < 0.95} />
            <Tile label="Right first time" value={pct(s.first_time_right_rate)} note="Visits with no complaint and nothing marked not met" watch={s.first_time_right_rate != null && s.first_time_right_rate < 0.9} />
            <Tile label="Complaints per 100 visits" value={s.complaints_per_100 == null ? '–' : String(s.complaints_per_100)} watch={s.complaints_per_100 != null && s.complaints_per_100 > 10} />
            <Tile label="Photos taken on site" value={pct(s.photos_on_site_rate)} note="The location recorded with each photo" watch={s.photos_on_site_rate != null && s.photos_on_site_rate < 0.9} />
            <Tile label="Time on site against plan" value={s.time_vs_plan == null ? '–' : `${Math.round(s.time_vs_plan * 100)}%`} note={plan.label} watch={plan.tone === 'watch'} />
            <Tile label="Planned vs on site" value={`${minutesText(s.avg_planned_minutes)} / ${minutesText(s.avg_on_site_minutes)}`} note="Average per visit" />
            <Tile
              label="Problems open now"
              value={String(s.open_issues ?? 0)}
              note={s.sla_breaches ? `${s.sla_breaches} past their response deadline` : s.avg_hours_to_resolve != null ? `Resolved in ${s.avg_hours_to_resolve} h on average` : 'None past their deadline'}
              watch={Boolean(s.sla_breaches)}
            />
          </div>

          {data.areas.length > 0 && (
            <Section title="Where complaints land">
              <p className="text-sm text-ink-2">The exact cleaning areas clients reported on most. Fixing these first helps the most.</p>
              <ul className="card divide-y divide-line">
                {data.areas.map((a) => (
                  <li key={a.area} className="flex flex-wrap items-center justify-between gap-2 p-3 text-sm">
                    <span>{a.area}</span>
                    <span className="font-semibold">
                      {a.complaints} complaint{a.complaints === 1 ? '' : 's'}
                    </span>
                  </li>
                ))}
              </ul>
            </Section>
          )}

          <Section title="Recent visits">
            <Table head={['When', 'Site', 'Planned', 'On site', 'How it went', '']}>
              {data.visits.map((v) => (
                <tr key={v.job_id} className="border-b border-line align-top last:border-0">
                  <td className="p-3 whitespace-nowrap">{when(v.scheduled_start)}</td>
                  <td className="p-3">{v.site_name}</td>
                  <td className="p-3 whitespace-nowrap">{minutesText(v.planned_minutes)}</td>
                  <td className="p-3 whitespace-nowrap">{minutesText(v.on_site_minutes)}</td>
                  <td className="p-3">
                    <span className={v.on_time && v.complaints === 0 && v.ticked_areas >= v.planned_areas ? '' : 'text-alert'}>{visitNotes(v).join(' · ')}</span>
                  </td>
                  <td className="p-3">
                    <Link to="/crew/$jobId" params={{ jobId: v.job_id }} className="link-action text-sm font-semibold text-primary">
                      Job sheet
                    </Link>
                  </td>
                </tr>
              ))}
            </Table>
          </Section>
        </>
      )}
    </div>
  )
}
