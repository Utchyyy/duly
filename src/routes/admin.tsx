import { createFileRoute } from '@tanstack/react-router'
import { useEffect, useState } from 'react'
import { Gate } from '#/components/Gate'
import { ConsoleShell, Stat } from '#/components/Shells'
import { supabase } from '#/lib/supabase'

export const Route = createFileRoute('/admin')({
  head: () => ({ meta: [{ title: 'Duly Admin' }] }),
  component: AdminPage,
})

const nav = [
  { label: 'Overview', active: true },
  { label: 'Verification queue' },
  { label: 'Disputes' },
  { label: 'DBS applications' },
  { label: 'Markets and policies' },
  { label: 'Payments ledger' },
]

function AdminPage() {
  return (
    <ConsoleShell suffix="Admin" nav={nav}>
      <Gate roles={['platform_admin']} allowSignUp={false} signInHeading="Duly Admin">
        <AdminOverview />
      </Gate>
    </ConsoleShell>
  )
}

type Policy = {
  segment: string
  payment_model: string
  first_release_pct: number
  first_release_on: string
  balance_release_hours: number
  platform_fee_pct: number | null
  min_verification_tier: number
}

function AdminOverview() {
  const [vendors, setVendors] = useState<number | null>(null)
  const [pendingClaims, setPendingClaims] = useState<number | null>(null)
  const [openIssues, setOpenIssues] = useState<number | null>(null)
  const [policies, setPolicies] = useState<Policy[]>([])

  useEffect(() => {
    const db = supabase()
    void db
      .from('organisations')
      .select('id', { count: 'exact', head: true })
      .eq('kind', 'vendor')
      .then(({ count }) => setVendors(count ?? 0))
    void db
      .from('verification_claims')
      .select('id', { count: 'exact', head: true })
      .in('status', ['self_declared', 'pending'])
      .then(({ count }) => setPendingClaims(count ?? 0))
    void db
      .from('issues')
      .select('id', { count: 'exact', head: true })
      .neq('status', 'resolved')
      .then(({ count }) => setOpenIssues(count ?? 0))
    void db
      .from('policies')
      .select(
        'segment, payment_model, first_release_pct, first_release_on, balance_release_hours, platform_fee_pct, min_verification_tier',
      )
      .eq('market', 'UK')
      .order('segment')
      .then(({ data }) => setPolicies(data ?? []))
  }, [])

  return (
    <div className="max-w-5xl space-y-8">
      <h1 className="text-3xl">Overview</h1>
      <div className="grid gap-4 sm:grid-cols-3">
        <Stat label="Vendors" value={vendors ?? '–'} />
        <Stat label="Claims to verify" value={pendingClaims ?? '–'} />
        <Stat label="Open issues" value={openIssues ?? '–'} />
      </div>
      <section className="space-y-3">
        <h2 className="text-xl">UK payment policies</h2>
        <div className="card overflow-x-auto">
          <table className="w-full text-left text-sm">
            <thead className="border-b border-line text-ink-2">
              <tr>
                <th className="p-3 font-medium">Segment</th>
                <th className="p-3 font-medium">Payment</th>
                <th className="p-3 font-medium">First release</th>
                <th className="p-3 font-medium">Balance</th>
                <th className="p-3 font-medium">Fee</th>
                <th className="p-3 font-medium">Min tier</th>
              </tr>
            </thead>
            <tbody>
              {policies.map((p) => (
                <tr key={p.segment} className="border-b border-line last:border-0">
                  <td className="p-3 font-medium">{p.segment}</td>
                  <td className="p-3">{p.payment_model.replace(/_/g, ' ')}</td>
                  <td className="p-3">
                    {p.first_release_pct}% on {p.first_release_on.replace('_', ' ')}
                  </td>
                  <td className="p-3">after {p.balance_release_hours}h, no complaint</td>
                  <td className="p-3">
                    {p.platform_fee_pct == null ? <span className="text-alert">not set</span> : `${p.platform_fee_pct}%`}
                  </td>
                  <td className="p-3">{p.min_verification_tier}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>
    </div>
  )
}
