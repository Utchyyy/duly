import { createFileRoute } from '@tanstack/react-router'
import { useState } from 'react'
import { Badge, ErrorNote, Loading, Table } from '#/components/ui'
import { label, money, must, useLoad, when } from '#/lib/format'
import { supabase } from '#/lib/supabase'

export const Route = createFileRoute('/admin/payments')({ component: AdminPayments })

function AdminPayments() {
  const [all, setAll] = useState(false)
  const { data, error, reload } = useLoad(async () => {
    let q = supabase()
      .from('payments')
      .select(
        'id, kind, amount, currency, status, due_at, paid_at, provider_ref, note, job:jobs(status, buyer:organisations!jobs_buyer_org_id_fkey(name), vendor:organisations!jobs_vendor_org_id_fkey(name)), contract:contracts(buyer:organisations!contracts_buyer_org_id_fkey(name), vendor:organisations!contracts_vendor_org_id_fkey(name))',
      )
      .order('due_at')
    if (!all) q = q.eq('status', 'pending')
    return must(await q)
  }, [all])
  const [refs, setRefs] = useState<Record<string, string>>({})
  const [actionError, setActionError] = useState<string | null>(null)

  async function markPaid(id: string) {
    setActionError(null)
    const { error: err } = await supabase().rpc('mark_payment_paid', { p_payment: id, p_reference: refs[id] ?? '' })
    if (err) setActionError(err.message)
    reload()
  }

  if (error) return <ErrorNote message={error} />
  if (!data) return <Loading />

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-3xl">Payments ledger</h1>
        <label className="flex min-h-[44px] items-center gap-2 text-sm">
          <input type="checkbox" className="size-5" checked={all} onChange={(e) => setAll(e.target.checked)} />
          Show paid
        </label>
      </div>
      <p className="text-sm text-ink-2">
        During the pilot, money moves by bank transfer. Record each one here with its bank reference. Releases can't be recorded
        before they're due, or while the job has an open issue. Card payments (Stripe) will replace this.
      </p>
      <ErrorNote message={actionError} />
      <Table head={['Due', 'What', 'Client → vendor', 'Amount', 'Status', '']}>
        {data.map((p) => {
          const due = p.due_at && new Date(p.due_at) <= new Date()
          const held = p.job?.status === 'disputed' && (p.kind === 'release' || p.kind === 'platform_fee')
          return (
            <tr key={p.id}>
              <td className={due && p.status === 'pending' ? 'font-semibold' : ''}>{when(p.due_at)}</td>
              <td>
                {label(p.kind)}
                <span className="block text-xs text-ink-2">{p.note}</span>
              </td>
              <td>
                {p.job?.buyer?.name ?? p.contract?.buyer?.name} → {p.job?.vendor?.name ?? p.contract?.vendor?.name}
              </td>
              <td>{money(p.amount, p.currency)}</td>
              <td>{held ? <Badge value="disputed">Held</Badge> : <Badge value={p.status} />}</td>
              <td>
                {p.status === 'pending' ? (
                  <div className="flex gap-1">
                    <input
                      className="field !min-h-[36px] w-32 text-xs"
                      placeholder="Bank ref"
                      value={refs[p.id] ?? ''}
                      onChange={(e) => setRefs((r) => ({ ...r, [p.id]: e.target.value }))}
                    />
                    <button className="btn btn-primary !min-h-[36px] text-xs" disabled={held} onClick={() => void markPaid(p.id)}>
                      {['escrow_hold', 'direct_debit', 'invoice'].includes(p.kind) ? 'Received' : 'Paid'}
                    </button>
                  </div>
                ) : (
                  <span className="text-xs text-ink-2">{p.provider_ref ?? when(p.paid_at)}</span>
                )}
              </td>
            </tr>
          )
        })}
        {data.length === 0 && (
          <tr>
            <td colSpan={6} className="text-ink-2">
              Nothing due.
            </td>
          </tr>
        )}
      </Table>
    </div>
  )
}
