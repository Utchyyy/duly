import { createFileRoute } from '@tanstack/react-router'
import { useState } from 'react'
import { Badge, ErrorNote, Loading, Section } from '#/components/ui'
import type { Database } from '#/lib/database.types'
import { day, must, useLoad, when } from '#/lib/format'
import { ACTION_TEXT, consequence, periodText, validMonths } from '#/lib/retention'
import { supabase } from '#/lib/supabase'

export const Route = createFileRoute('/admin/retention')({ component: AdminRetention })

type Rule = Database['public']['Functions']['admin_retention_report']['Returns'][number]

function AdminRetention() {
  const { data, error, reload } = useLoad(async () => {
    const db = supabase()
    const [rules, runs] = await Promise.all([
      db.rpc('admin_retention_report'),
      db.from('data_retention_runs').select('id, ran_at, rule_key, action, rows_affected, note').order('ran_at', { ascending: false }).order('id', { ascending: false }).limit(20),
    ])
    return { rules: must(rules), runs: must(runs) }
  }, [])

  if (error && !data) return <ErrorNote message={error} />
  if (!data) return <Loading />
  const on = data.rules.filter((r) => r.enabled).length

  return (
    <div className="space-y-8">
      <div>
        <h1 className="text-3xl">Data retention</h1>
        <p className="mt-1 max-w-3xl text-sm text-ink-2">
          How long Duly keeps personal data. Every rule starts switched off: nothing is cleared or deleted until a person has read the rule, set the period and turned it on. A daily scan (03:45 UTC) applies the rules that are
          on, in batches, and the list at the bottom shows what it did. Photos and documents in storage cannot be removed by this scan yet: that rule only counts what is due. {on} of {data.rules.length} rules are on.
        </p>
      </div>
      <Section title="Rules">
        <div className="space-y-3">
          {data.rules.map((r) => (
            <RuleCard key={r.key} rule={r} onChange={reload} />
          ))}
        </div>
      </Section>
      <Section title="What the scan has done">
        {data.runs.length === 0 ? (
          <p className="text-sm text-ink-2">Nothing yet. A rule that is switched on appears here the first time it acts.</p>
        ) : (
          <ul className="card divide-y divide-line">
            {data.runs.map((u) => (
              <li key={u.id} className="flex flex-wrap items-center justify-between gap-2 p-3 text-sm">
                <span>
                  <span className="font-medium">{data.rules.find((r) => r.key === u.rule_key)?.title ?? u.rule_key}</span> · {when(u.ran_at)}
                </span>
                <span className={u.note ? 'text-alert' : 'text-ink-2'}>{u.note ?? `${u.rows_affected} record${u.rows_affected === 1 ? '' : 's'} ${u.action === 'delete' ? 'deleted' : 'cleared'}`}</span>
              </li>
            ))}
          </ul>
        )}
      </Section>
    </div>
  )
}

function RuleCard({ rule, onChange }: { rule: Rule; onChange: () => void }) {
  const [months, setMonths] = useState(String(rule.months))
  const [confirming, setConfirming] = useState<boolean | null>(null)
  const [busy, setBusy] = useState(false)
  const [problem, setProblem] = useState<string | null>(null)
  const parsed = validMonths(months, rule.key)
  const changed = parsed.ok && parsed.months !== rule.months

  async function save(enabled: boolean) {
    if (!parsed.ok) return
    setBusy(true)
    setProblem(null)
    const { error: err } = await supabase().rpc('admin_set_retention_rule', { p_key: rule.key, p_months: parsed.months, p_enabled: enabled })
    setBusy(false)
    if (err) return setProblem(err.message)
    setConfirming(null)
    onChange()
  }

  return (
    <div className={`card space-y-3 p-4 ${rule.enabled && rule.action !== 'report' ? 'border-primary' : ''}`}>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="max-w-2xl">
          <p className="font-semibold">{rule.title}</p>
          <p className="text-sm">{rule.description}</p>
          <p className="mt-1 text-xs text-ink-2">Why: {rule.basis}</p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <Badge value={rule.action === 'report' ? 'awaiting' : 'locked'}>{ACTION_TEXT[rule.action] ?? rule.action}</Badge>
          <Badge value={rule.enabled ? 'accepted' : 'withdrawn'}>{rule.enabled ? 'On' : 'Off'}</Badge>
        </div>
      </div>
      <dl className="grid grid-cols-2 gap-x-4 gap-y-1 text-sm sm:grid-cols-3">
        <div>
          <dt className="text-ink-2">Due now</dt>
          <dd className="font-semibold">{rule.due_now}</dd>
        </div>
        <div>
          <dt className="text-ink-2">Period</dt>
          <dd className="font-semibold">{periodText(rule.months)}</dd>
        </div>
        <div>
          <dt className="text-ink-2">Last acted</dt>
          <dd className="font-semibold">{rule.last_run_at ? `${day(rule.last_run_at)} · ${rule.last_rows} record${rule.last_rows === 1 ? '' : 's'}` : 'Never'}</dd>
        </div>
      </dl>
      <div className="flex flex-wrap items-end gap-3">
        <div>
          <label className="block text-sm font-medium" htmlFor={`months-${rule.key}`}>
            Keep for (months)
          </label>
          <input id={`months-${rule.key}`} className="field w-32" inputMode="numeric" value={months} onChange={(e) => { setMonths(e.target.value); setConfirming(null) }} />
        </div>
        {confirming === null && (
          <>
            {changed && (
              <button className="btn btn-ghost" disabled={busy} onClick={() => void save(rule.enabled)}>
                Save period
              </button>
            )}
            {!rule.enabled ? (
              <button className="btn btn-primary" disabled={busy || !parsed.ok} onClick={() => setConfirming(true)}>
                Turn on
              </button>
            ) : (
              <button className="btn btn-ghost" disabled={busy || !parsed.ok} onClick={() => void save(false)}>
                Turn off
              </button>
            )}
          </>
        )}
      </div>
      {confirming && (
        <div className="space-y-2 rounded-lg bg-alert-bg p-3 text-sm text-alert">
          <p>{consequence(rule.action, rule.due_now)}</p>
          <div className="flex gap-2">
            <button className="btn btn-primary" disabled={busy} onClick={() => void save(true)}>
              Yes, turn it on
            </button>
            <button className="btn btn-ghost" onClick={() => setConfirming(null)}>
              Not yet
            </button>
          </div>
        </div>
      )}
      {!parsed.ok && <p className="text-sm text-alert">{parsed.reason}</p>}
      <ErrorNote message={problem} />
    </div>
  )
}
