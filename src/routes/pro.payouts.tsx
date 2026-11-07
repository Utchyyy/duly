import { createFileRoute } from '@tanstack/react-router'
import { Stat } from '#/components/Shells'
import { Badge, ErrorNote, Loading, Table } from '#/components/ui'
import { day, money, must, useLoad, when } from '#/lib/format'
import { supabase } from '#/lib/supabase'
import { useVendor } from '#/lib/vendor'

export const Route = createFileRoute('/pro/payouts')({ component: ProPayouts })

function ProPayouts() {
  const vendor = useVendor()!
  const { data, error } = useLoad(async () => {
    const rows = must(
      await supabase()
        .from('payments')
        .select('id, kind, amount, currency, status, due_at, paid_at, note, job:jobs!inner(vendor_org_id, scheduled_start, site:sites(name))')
        .eq('job.vendor_org_id', vendor.id)
        .in('kind', ['release', 'platform_fee'])
        .order('due_at', { ascending: false }),
    )
    return rows
  }, [vendor.id])

  if (!vendor.isAdmin) return <p className="text-ink-2">Only your company's admin can see payouts.</p>
  if (error) return <ErrorNote message={error} />
  if (!data) return <Loading />

  const currency = data[0]?.currency ?? 'GBP'
  const sum = (f: (r: NonNullable<typeof data>[number]) => boolean) =>
    data.filter(f).reduce((t, r) => t + (r.kind === 'platform_fee' ? -Number(r.amount) : Number(r.amount)), 0)

  return (
    <div className="space-y-8">
      <h1 className="text-3xl">Payouts</h1>
      <div className="grid gap-4 sm:grid-cols-2">
        <Stat label="Paid to you" value={money(sum((r) => r.status === 'succeeded' && r.kind === 'release'), currency)} />
        <Stat label="Coming" value={money(sum((r) => r.status === 'pending'), currency)} note="Released on the schedule your clients' plans set" />
      </div>
      <Table head={['Clean', 'What', 'Amount', 'Due', 'Status']}>
        {data.map((p) => (
          <tr key={p.id}>
            <td>
              {day(p.job.scheduled_start)} · {p.job.site?.name}
            </td>
            <td>{p.note}</td>
            <td>{p.kind === 'platform_fee' ? `−${money(p.amount, p.currency)}` : money(p.amount, p.currency)}</td>
            <td>{p.status === 'succeeded' ? `Paid ${when(p.paid_at)}` : when(p.due_at)}</td>
            <td>
              <Badge value={p.status} />
            </td>
          </tr>
        ))}
        {data.length === 0 && (
          <tr>
            <td colSpan={5} className="text-ink-2">
              No payouts yet. They appear once a client approves a clean.
            </td>
          </tr>
        )}
      </Table>
    </div>
  )
}
