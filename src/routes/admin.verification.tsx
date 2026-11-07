import { createFileRoute } from '@tanstack/react-router'
import { useState } from 'react'
import { Badge, ErrorNote, Loading } from '#/components/ui'
import { day, label, must, useLoad } from '#/lib/format'
import { supabase } from '#/lib/supabase'

export const Route = createFileRoute('/admin/verification')({ component: AdminVerification })

const tiers = ['0 · Unverified', '1 · ID checked', '2 · Insured and checked', '3 · Fully verified']

function AdminVerification() {
  const { data, error, reload } = useLoad(async () => {
    const db = supabase()
    const [vendors, claims] = await Promise.all([
      db.from('organisations').select('id, name, verification_tier, companies_house_no').eq('kind', 'vendor').order('name'),
      db.from('verification_claims').select('id, org_id, kind, status, reference, valid_until, notes, created_at').is('subject_user_id', null).order('created_at'),
    ])
    return { vendors: must(vendors), claims: must(claims) }
  }, [])
  const [actionError, setActionError] = useState<string | null>(null)

  async function setClaim(id: string, status: 'verified' | 'rejected') {
    setActionError(null)
    const db = supabase()
    const { data: user } = await db.auth.getUser()
    const { error: err } = await db
      .from('verification_claims')
      .update({ status, verified_by: user.user?.id, verified_at: new Date().toISOString() })
      .eq('id', id)
    if (err) setActionError(err.message)
    reload()
  }

  async function setTier(orgId: string, tier: number) {
    setActionError(null)
    const { error: err } = await supabase().from('organisations').update({ verification_tier: tier }).eq('id', orgId)
    if (err) setActionError(err.message)
    reload()
  }

  if (error) return <ErrorNote message={error} />
  if (!data) return <Loading />
  const waiting = data.claims.filter((c) => c.status === 'pending' || c.status === 'self_declared').length

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-3xl">Verification</h1>
        <p className="mt-1 text-ink-2">
          {waiting} item(s) waiting. Check each reference against the source (Companies House, the insurer), then set the vendor's
          level. Vendors appear in search from level 1 (level 2 for enterprise and healthcare clients).
        </p>
      </div>
      <ErrorNote message={actionError} />
      {data.vendors.map((v) => {
        const claims = data.claims.filter((c) => c.org_id === v.id)
        return (
          <div key={v.id} className="card space-y-3 p-4">
            <div className="flex flex-wrap items-center justify-between gap-3">
              <p className="font-semibold">{v.name}</p>
              <select
                className="field w-auto"
                value={v.verification_tier}
                aria-label={`Verification level for ${v.name}`}
                onChange={(e) => void setTier(v.id, Number(e.target.value))}
              >
                {tiers.map((t, i) => (
                  <option key={t} value={i}>
                    {t}
                  </option>
                ))}
              </select>
            </div>
            {claims.length === 0 ? (
              <p className="text-sm text-ink-2">Nothing submitted.</p>
            ) : (
              <ul className="divide-y divide-line">
                {claims.map((c) => (
                  <li key={c.id} className="flex flex-wrap items-center justify-between gap-3 py-2 text-sm">
                    <div>
                      <p className="font-medium">
                        {label(c.kind)} · {c.reference}
                      </p>
                      <p className="text-ink-2">
                        Sent {day(c.created_at)}
                        {c.valid_until ? ` · valid until ${day(c.valid_until)}` : ''}
                        {c.notes ? ` · ${c.notes}` : ''}
                      </p>
                    </div>
                    <div className="flex items-center gap-2">
                      <Badge value={c.status} />
                      {c.status !== 'verified' && (
                        <button className="btn btn-primary text-xs" onClick={() => void setClaim(c.id, 'verified')}>
                          Verify
                        </button>
                      )}
                      {c.status !== 'rejected' && (
                        <button className="btn btn-ghost text-xs" onClick={() => void setClaim(c.id, 'rejected')}>
                          Reject
                        </button>
                      )}
                    </div>
                  </li>
                ))}
              </ul>
            )}
          </div>
        )
      })}
    </div>
  )
}
