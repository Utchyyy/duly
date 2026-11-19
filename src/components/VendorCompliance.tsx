import { useState } from 'react'
import { Badge, ErrorNote, Section } from '#/components/ui'
import { groupByVendor, REQUIRABLE_KINDS, STATE_TEXT } from '#/lib/compliance'
import type { ComplianceRow } from '#/lib/compliance'
import type { Database } from '#/lib/database.types'
import { day, label } from '#/lib/format'
import { supabase } from '#/lib/supabase'

type ClaimKind = Database['public']['Enums']['claim_kind']

/** What the Enterprise requires of every vendor, and how each roster vendor stands against it. The states are worked out in SQL. */
export function VendorCompliance({ enterpriseId, canManage, required, rows, onChange }: { enterpriseId: string; canManage: boolean; required: string[]; rows: ComplianceRow[]; onChange: () => void }) {
  const [editing, setEditing] = useState(false)
  const [picked, setPicked] = useState<string[]>(required)
  const [busy, setBusy] = useState<string | null>(null)
  const [rejecting, setRejecting] = useState<string | null>(null)
  const [reason, setReason] = useState('')
  const [error, setError] = useState<string | null>(null)

  async function saveRequirements() {
    setBusy('requirements')
    setError(null)
    const { error: err } = await supabase().rpc('enterprise_set_requirements', { p_enterprise: enterpriseId, p_kinds: picked as ClaimKind[] })
    setBusy(null)
    if (err) return setError(err.message)
    setEditing(false)
    onChange()
  }

  async function review(claimId: string, decision: 'accepted' | 'rejected') {
    setBusy(claimId)
    setError(null)
    const { error: err } = await supabase().rpc('enterprise_review_claim', { p_enterprise: enterpriseId, p_claim: claimId, p_decision: decision, p_note: decision === 'rejected' ? reason.trim() : undefined })
    setBusy(null)
    if (err) return setError(err.message)
    setRejecting(null)
    setReason('')
    onChange()
  }

  const vendors = groupByVendor(rows)

  return (
    <Section title="What you require of your vendors">
      <ErrorNote message={error} />
      {!editing ? (
        <div className="flex flex-wrap items-center gap-3">
          {required.length === 0 ? (
            <p className="text-sm text-ink-2">Nothing required yet. Choose the evidence you want from every vendor, then check what each one sends.</p>
          ) : (
            <ul className="flex flex-wrap gap-2">
              {required.map((k) => (
                <li key={k} className="rounded-full bg-tint px-3 py-1 text-sm font-medium text-primary">
                  {label(k)}
                </li>
              ))}
            </ul>
          )}
          {canManage && (
            <button className="btn btn-ghost text-sm" onClick={() => { setPicked(required); setEditing(true) }}>
              {required.length === 0 ? 'Choose what to require' : 'Change'}
            </button>
          )}
        </div>
      ) : (
        <div className="card space-y-3 p-4">
          <fieldset className="space-y-1">
            <legend className="text-sm font-medium">Company evidence you need from every vendor</legend>
            {REQUIRABLE_KINDS.map((k) => (
              <label key={k} className="flex min-h-[44px] cursor-pointer items-center gap-3 text-sm">
                <input type="checkbox" className="size-5 accent-[var(--color-primary)]" checked={picked.includes(k)} onChange={(e) => setPicked((p) => (e.target.checked ? [...p, k] : p.filter((x) => x !== k)))} />
                {label(k)}
              </label>
            ))}
          </fieldset>
          <p className="text-xs text-ink-2">DBS and right to work are checked per person, not for the company, so they are not listed here.</p>
          <div className="flex gap-2">
            <button className="btn btn-primary" disabled={busy === 'requirements'} onClick={() => void saveRequirements()}>
              Save
            </button>
            <button className="btn btn-ghost" onClick={() => setEditing(false)}>
              Cancel
            </button>
          </div>
        </div>
      )}

      {required.length > 0 && vendors.length > 0 && (
        <div className="space-y-4">
          <h3 className="text-lg">Evidence from each vendor</h3>
          {vendors.map((v) => (
            <div key={v.vendor_org_id} className="card space-y-2 p-4">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <p className="font-semibold">{v.vendor_name}</p>
                <Badge value={v.complete ? 'accepted' : v.needsReview > 0 ? 'awaiting' : 'rejected'}>
                  {v.complete ? 'All accepted' : `${v.accepted} of ${v.rows.length} accepted`}
                </Badge>
              </div>
              <ul className="divide-y divide-line">
                {v.rows.map((r) => (
                  <li key={r.kind} className="space-y-2 py-2 text-sm">
                    <div className="flex flex-wrap items-center justify-between gap-2">
                      <div>
                        <p className="font-medium">
                          {label(r.kind)}
                          {r.reference ? ` · ${r.reference}` : ''}
                        </p>
                        <p className="text-ink-2">
                          {r.valid_until ? `Valid until ${day(r.valid_until)}` : r.claim_id ? 'No expiry date given' : 'The vendor has not sent this'}
                          {r.reviewed_at ? ` · reviewed ${day(r.reviewed_at)}` : ''}
                        </p>
                        {r.note && <p className="text-ink-2">{r.state === 'rejected' ? 'Reason: ' : 'Note: '}{r.note}</p>}
                      </div>
                      <div className="flex flex-wrap items-center gap-2">
                        <Badge value={r.state}>{STATE_TEXT[r.state] ?? r.state}</Badge>
                        {canManage && r.claim_id && r.state !== 'accepted' && r.state !== 'not_sent' && (
                          <button className="btn btn-primary text-sm" disabled={busy === r.claim_id} onClick={() => void review(r.claim_id!, 'accepted')}>
                            Accept
                          </button>
                        )}
                        {canManage && r.claim_id && r.state !== 'rejected' && r.state !== 'not_sent' && (
                          <button className="btn btn-ghost text-sm" onClick={() => { setRejecting(r.claim_id); setReason('') }}>
                            Reject
                          </button>
                        )}
                      </div>
                    </div>
                    {rejecting === r.claim_id && (
                      <div className="flex flex-wrap items-end gap-2">
                        <div className="min-w-[14rem] flex-1">
                          <label className="block text-sm font-medium" htmlFor={`reason-${r.claim_id}`}>
                            Why is it rejected? The vendor sees this.
                          </label>
                          <input id={`reason-${r.claim_id}`} className="field mt-1" value={reason} maxLength={500} onChange={(e) => setReason(e.target.value)} />
                        </div>
                        <button className="btn btn-primary" disabled={!reason.trim() || busy === r.claim_id} onClick={() => void review(r.claim_id!, 'rejected')}>
                          Reject it
                        </button>
                        <button className="btn btn-ghost" onClick={() => setRejecting(null)}>
                          Not now
                        </button>
                      </div>
                    )}
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>
      )}
    </Section>
  )
}
