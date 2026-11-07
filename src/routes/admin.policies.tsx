import { createFileRoute } from '@tanstack/react-router'
import { useState } from 'react'
import { ErrorNote, Loading } from '#/components/ui'
import type { Database } from '#/lib/database.types'
import { label, must, useLoad } from '#/lib/format'
import { supabase } from '#/lib/supabase'

export const Route = createFileRoute('/admin/policies')({ component: AdminPolicies })

type Policy = Database['public']['Tables']['policies']['Row']

function AdminPolicies() {
  const { data, error, reload } = useLoad(async () => {
    const db = supabase()
    const [markets, policies] = await Promise.all([
      db.from('markets').select('code, name, currency, tax_name, tax_rate, data_region'),
      db.from('policies').select('*').order('market').order('segment'),
    ])
    return { markets: must(markets), policies: must(policies) }
  }, [])

  if (error) return <ErrorNote message={error} />
  if (!data) return <Loading />

  return (
    <div className="space-y-6">
      <h1 className="text-3xl">Markets and policies</h1>
      {data.markets.map((m) => (
        <p key={m.code} className="text-sm text-ink-2">
          <strong className="text-ink">{m.name}</strong> · {m.currency} · {m.tax_name} {m.tax_rate}% · data in {m.data_region}
        </p>
      ))}
      <p className="text-sm text-ink-2">
        These rules drive every payment schedule and who appears in search. Changes apply to approvals from now on, not to money
        already scheduled.
      </p>
      <div className="space-y-3">
        {data.policies.map((p) => (
          <PolicyRow key={`${p.market}-${p.segment}`} policy={p} onSaved={reload} />
        ))}
      </div>
    </div>
  )
}

function PolicyRow({ policy, onSaved }: { policy: Policy; onSaved: () => void }) {
  const [p, setP] = useState(policy)
  const [error, setError] = useState<string | null>(null)
  const [saved, setSaved] = useState(false)
  const set = <TKey extends keyof Policy>(k: TKey, v: Policy[TKey]) => {
    setP((x) => ({ ...x, [k]: v }))
    setSaved(false)
  }

  async function save() {
    setError(null)
    const { error: err } = await supabase()
      .from('policies')
      .update({
        payment_model: p.payment_model,
        first_release_pct: p.first_release_pct,
        first_release_on: p.first_release_on,
        balance_release_hours: p.balance_release_hours,
        platform_fee_pct: p.platform_fee_pct,
        min_verification_tier: p.min_verification_tier,
        reclean_window_hours: p.reclean_window_hours,
        lateness_tolerance_min: p.lateness_tolerance_min,
      })
      .eq('market', p.market)
      .eq('segment', p.segment)
    if (err) return setError(err.message)
    setSaved(true)
    onSaved()
  }

  const num = (k: keyof Policy, text: string, step = 1) => (
    <label className="text-xs text-ink-2">
      {text}
      <input
        type="number"
        step={step}
        className="field mt-1 !min-h-[40px] text-sm text-ink"
        value={(p[k] as number | null) ?? ''}
        onChange={(e) => set(k, (e.target.value === '' ? null : Number(e.target.value)) as never)}
      />
    </label>
  )

  return (
    <div className="card space-y-3 p-4">
      <p className="font-semibold">
        {p.market} · {label(p.segment)}
      </p>
      <div className="grid gap-3 sm:grid-cols-4">
        <label className="text-xs text-ink-2">
          Payment model
          <select className="field mt-1 !min-h-[40px] text-sm text-ink" value={p.payment_model} onChange={(e) => set('payment_model', e.target.value)}>
            <option value="escrow_one_off">Escrow, per clean</option>
            <option value="monthly_in_advance">Monthly in advance</option>
            <option value="invoice_terms">Invoice terms</option>
          </select>
        </label>
        {num('first_release_pct', 'First release %')}
        <label className="text-xs text-ink-2">
          First release on
          <select className="field mt-1 !min-h-[40px] text-sm text-ink" value={p.first_release_on} onChange={(e) => set('first_release_on', e.target.value)}>
            <option value="approval">Approval</option>
            <option value="check_in">Check-in</option>
            <option value="month_end">Month end</option>
          </select>
        </label>
        {num('balance_release_hours', 'Balance after (hours)')}
        {num('platform_fee_pct', 'Duly fee %', 0.5)}
        {num('min_verification_tier', 'Min vendor level')}
        {num('reclean_window_hours', 'Re-clean window (h)')}
        {num('lateness_tolerance_min', 'Late after (min)')}
      </div>
      <div className="flex items-center gap-3">
        <button className="btn btn-primary" onClick={() => void save()}>
          Save
        </button>
        {saved && <span className="text-sm text-primary">Saved</span>}
        {p.platform_fee_pct == null && <span className="text-sm text-alert">Duly fee not set</span>}
      </div>
      <ErrorNote message={error} />
    </div>
  )
}
