import { createFileRoute } from '@tanstack/react-router'
import { useState } from 'react'
import { Empty } from '#/components/Shells'
import { ErrorNote, Loading, Table } from '#/components/ui'
import { must, useLoad } from '#/lib/format'
import { pct, rangeDates, timeAgainstPlan } from '#/lib/measures'
import type { RangeKey } from '#/lib/measures'
import { supabase } from '#/lib/supabase'

export const Route = createFileRoute('/admin/operations')({ component: AdminOperations })

function AdminOperations() {
  const [range, setRange] = useState<RangeKey>('30')
  const { data, error } = useLoad(async () => {
    const { from, to } = rangeDates(Number(range))
    return must(await supabase().rpc('platform_operations', { p_from: from, p_to: to }))
  }, [range])

  if (error) return <ErrorNote message={error} />
  if (!data) return <Loading />

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-3xl">Operations</h1>
          <p className="mt-1 max-w-2xl text-sm text-ink-2">
            How each vendor's visits went against their plan, side by side. Worked out in the database from check-ins, ticks, photos, and what clients reported. The weakest on "right first time" come first. Safeguarding reports are never counted here.
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
      {data.length === 0 ? (
        <Empty title="No checked-in visits in this period">Vendors appear here once a cleaner has checked in to one of their jobs.</Empty>
      ) : (
        <Table head={['Vendor', 'Visits', 'On time', 'Areas ticked', 'Right first time', 'Complaints per 100', 'Photos on site', 'Time vs plan', 'Open problems']}>
          {data.map((v) => {
            const plan = timeAgainstPlan(v.time_vs_plan)
            return (
              <tr key={v.vendor_org_id} className="border-b border-line last:border-0">
                <td className="p-3 font-medium">{v.vendor_name}</td>
                <td className="p-3">{v.visits}</td>
                <td className={`p-3 ${v.on_time_rate != null && v.on_time_rate < 0.9 ? 'font-semibold text-alert' : ''}`}>{pct(v.on_time_rate)}</td>
                <td className={`p-3 ${v.plan_followed_rate != null && v.plan_followed_rate < 0.95 ? 'font-semibold text-alert' : ''}`}>{pct(v.plan_followed_rate)}</td>
                <td className={`p-3 ${v.first_time_right_rate != null && v.first_time_right_rate < 0.9 ? 'font-semibold text-alert' : ''}`}>{pct(v.first_time_right_rate)}</td>
                <td className="p-3">{v.complaints_per_100 ?? '–'}</td>
                <td className={`p-3 ${v.photos_on_site_rate != null && v.photos_on_site_rate < 0.9 ? 'font-semibold text-alert' : ''}`}>{pct(v.photos_on_site_rate)}</td>
                <td className={`p-3 ${plan.tone === 'watch' ? 'font-semibold text-alert' : ''}`} title={plan.label}>
                  {v.time_vs_plan == null ? '–' : `${Math.round(v.time_vs_plan * 100)}%`}
                </td>
                <td className={`p-3 ${v.sla_breaches ? 'font-semibold text-alert' : ''}`}>
                  {v.open_issues ?? 0}
                  {v.sla_breaches ? ` (${v.sla_breaches} overdue)` : ''}
                </td>
              </tr>
            )
          })}
        </Table>
      )}
    </div>
  )
}
