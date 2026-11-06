import { createFileRoute } from '@tanstack/react-router'
import { useEffect, useState } from 'react'
import { Gate } from '#/components/Gate'
import { ConsoleShell, Empty, Stat } from '#/components/Shells'
import { useAuth } from '#/lib/auth'
import { supabase } from '#/lib/supabase'

export const Route = createFileRoute('/pro')({
  head: () => ({ meta: [{ title: 'Duly Pro' }] }),
  component: ProPage,
})

const nav = [
  { label: 'Today', active: true },
  { label: 'Quotes' },
  { label: 'Jobs' },
  { label: 'Shifts and crew' },
  { label: 'Verification' },
  { label: 'Payouts' },
]

function ProPage() {
  return (
    <ConsoleShell suffix="Pro" nav={nav}>
      <Gate roles={['vendor_admin', 'dispatcher']} allowSignUp={false} signInHeading="Duly Pro">
        <ProToday />
      </Gate>
    </ConsoleShell>
  )
}

type TownRow = { town: string; open_shifts: number; workers: number; balance: number; status: string }

function ProToday() {
  const { memberships } = useAuth()
  const vendor = memberships.find((m) => m.org?.kind === 'vendor')?.org ?? null
  const [jobsToday, setJobsToday] = useState<number | null>(null)
  const [openShifts, setOpenShifts] = useState<number | null>(null)
  const [quotesWaiting, setQuotesWaiting] = useState<number | null>(null)
  const [towns, setTowns] = useState<TownRow[]>([])

  useEffect(() => {
    if (!vendor) return
    const db = supabase()
    const start = new Date()
    start.setHours(0, 0, 0, 0)
    const end = new Date(start)
    end.setDate(end.getDate() + 1)
    void db
      .from('jobs')
      .select('id', { count: 'exact', head: true })
      .eq('vendor_org_id', vendor.id)
      .gte('scheduled_start', start.toISOString())
      .lt('scheduled_start', end.toISOString())
      .then(({ count }) => setJobsToday(count ?? 0))
    void db
      .from('shifts')
      .select('id', { count: 'exact', head: true })
      .eq('vendor_org_id', vendor.id)
      .eq('status', 'open')
      .then(({ count }) => setOpenShifts(count ?? 0))
    void db
      .from('quotes')
      .select('id', { count: 'exact', head: true })
      .eq('vendor_org_id', vendor.id)
      .eq('status', 'invited')
      .then(({ count }) => setQuotesWaiting(count ?? 0))
    void db.rpc('demand_by_town').then(({ data }) => setTowns((data ?? []) as TownRow[]))
  }, [vendor?.id])

  if (!vendor) {
    return <Empty title="You're not attached to a vendor yet">Ask a Duly admin to add you to your company.</Empty>
  }

  return (
    <div className="max-w-5xl space-y-8">
      <div>
        <p className="text-sm font-medium text-primary">{vendor.name}</p>
        <h1 className="mt-1 text-3xl">Today</h1>
      </div>
      <div className="grid gap-4 sm:grid-cols-3">
        <Stat label="Jobs today" value={jobsToday ?? '–'} />
        <Stat label="Quote requests waiting" value={quotesWaiting ?? '–'} />
        <Stat label="Open shifts" value={openShifts ?? '–'} />
      </div>
      <section className="space-y-3">
        <h2 className="text-xl">Labour by town</h2>
        <div className="card overflow-x-auto">
          <table className="w-full text-left text-sm">
            <thead className="border-b border-line text-ink-2">
              <tr>
                <th className="p-3 font-medium">Town</th>
                <th className="p-3 font-medium">Open shifts</th>
                <th className="p-3 font-medium">Workers</th>
                <th className="p-3 font-medium">Status</th>
              </tr>
            </thead>
            <tbody>
              {towns.map((t) => (
                <tr key={t.town} className="border-b border-line last:border-0">
                  <td className="p-3 font-medium">{t.town}</td>
                  <td className="p-3">{t.open_shifts}</td>
                  <td className="p-3">{t.workers}</td>
                  <td className="p-3">
                    <span
                      className={`rounded-full px-2.5 py-1 text-xs font-semibold ${
                        t.status === 'Deficit' ? 'bg-alert-bg text-alert' : 'bg-tint text-primary'
                      }`}
                    >
                      {t.status}
                    </span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>
    </div>
  )
}
