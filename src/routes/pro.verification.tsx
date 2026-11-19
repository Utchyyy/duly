import { createFileRoute } from '@tanstack/react-router'
import { useState } from 'react'
import type { FormEvent } from 'react'
import { ClaimDocument } from '#/components/ClaimDocument'
import { Badge, ErrorNote, Field, Loading, Section, Table } from '#/components/ui'
import { CLAIM_FILE_ACCEPT } from '#/lib/claimEvidence'
import { attachClaimDocument, removeClaimDocument } from '#/lib/claimEvidenceClient'
import type { Database } from '#/lib/database.types'
import { day, label, must, useLoad } from '#/lib/format'
import { supabase } from '#/lib/supabase'
import { useVendor } from '#/lib/vendor'

export const Route = createFileRoute('/pro/verification')({ component: ProVerification })

type ClaimKind = Database['public']['Enums']['claim_kind']

const kinds: { value: ClaimKind; text: string; hint: string }[] = [
  { value: 'companies_house', text: 'Companies House registration', hint: 'Company number' },
  { value: 'public_liability_insurance', text: 'Public liability insurance', hint: 'Insurer and policy number' },
  { value: 'right_to_work', text: 'Right-to-work checks on staff', hint: 'How you check (e.g. Home Office share codes)' },
  { value: 'dbs', text: 'DBS checks on staff', hint: 'Level and how many staff are checked' },
  { value: 'chas', text: 'CHAS', hint: 'Membership number' },
  { value: 'safecontractor', text: 'SafeContractor', hint: 'Membership number' },
  { value: 'iso_9001', text: 'ISO 9001', hint: 'Certificate number' },
  { value: 'other', text: 'Other', hint: 'What it is' },
]

const tiers = ['Unverified', 'ID checked', 'Insured and checked', 'Fully verified']

function ProVerification() {
  const vendor = useVendor()!
  const { data, error, reload } = useLoad(async () => {
    const db = supabase()
    const [claims, org, reviews] = await Promise.all([
      db.from('verification_claims').select('id, kind, status, reference, valid_until, notes, created_at, evidence_path').eq('org_id', vendor.id).is('subject_user_id', null).order('created_at'),
      db.from('organisations').select('verification_tier, companies_house_no').eq('id', vendor.id).single(),
      // What each Enterprise you work for said about these claims (row security shows you only decisions on your own).
      db.from('enterprise_claim_reviews').select('claim_id, decision, note, reviewed_at, enterprise:organisations!enterprise_claim_reviews_enterprise_org_id_fkey(name)').order('reviewed_at'),
    ])
    return { claims: must(claims), org: must(org), reviews: must(reviews) }
  }, [vendor.id])

  const [kind, setKind] = useState<ClaimKind>('companies_house')
  const [reference, setReference] = useState('')
  const [validUntil, setValidUntil] = useState('')
  const [notes, setNotes] = useState('')
  const [file, setFile] = useState<File | null>(null)
  const [fileKey, setFileKey] = useState(0)
  const [rowBusy, setRowBusy] = useState<string | null>(null)
  const [rowError, setRowError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [formError, setFormError] = useState<string | null>(null)

  async function submit(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setFormError(null)
    const { data: created, error: err } = await supabase()
      .from('verification_claims')
      .insert({ org_id: vendor.id, kind, reference: reference.trim(), valid_until: validUntil || null, notes: notes.trim() || null, status: 'pending' })
      .select('id')
      .single()
    if (err || !created) {
      setBusy(false)
      return setFormError(err?.message ?? 'The claim could not be saved.')
    }
    // The claim is saved first; if the document then fails, the claim stands and the vendor can attach it again from the list.
    const fileProblem = file ? await attachClaimDocument(vendor.id, created.id, file) : null
    setBusy(false)
    if (fileProblem) setFormError(`Your claim was saved, but the document was not attached. ${fileProblem}`)
    setReference('')
    setValidUntil('')
    setNotes('')
    setFile(null)
    setFileKey((k) => k + 1)
    reload()
  }

  async function attach(claimId: string, picked: File | undefined, previous: string | null) {
    if (!picked) return
    setRowBusy(claimId)
    setRowError(null)
    setRowError(await attachClaimDocument(vendor.id, claimId, picked, previous))
    setRowBusy(null)
    reload()
  }

  async function remove(claimId: string, path: string) {
    setRowBusy(claimId)
    setRowError(null)
    setRowError(await removeClaimDocument(claimId, path))
    setRowBusy(null)
    reload()
  }

  if (error) return <ErrorNote message={error} />
  if (!data) return <Loading />

  return (
    <div className="space-y-8">
      <div>
        <h1 className="text-3xl">Verification</h1>
        <p className="mt-2 text-ink-2">
          Your level: <strong>{tiers[data.org.verification_tier]}</strong>. Duly checks each item you send and raises your level.
          Verified badges show to clients, and many clients only see verified vendors.
        </p>
      </div>
      <ErrorNote message={rowError} />
      <Section title="What you've sent">
        <Table head={['Check', 'Reference', 'Valid until', 'Status', 'Document', 'Your Enterprises']}>
          {data.claims.map((c) => (
            <tr key={c.id}>
              <td>{kinds.find((k) => k.value === c.kind)?.text ?? label(c.kind)}</td>
              <td>{c.reference}</td>
              <td>{day(c.valid_until)}</td>
              <td>
                <Badge value={c.status} />
              </td>
              <td className="space-y-1">
                {c.evidence_path && <ClaimDocument path={c.evidence_path} />}
                {(c.status === 'pending' || c.status === 'self_declared') && (
                  <span className="flex flex-wrap gap-2">
                    <label className="btn btn-ghost cursor-pointer text-sm">
                      {c.evidence_path ? 'Replace' : 'Attach a document'}
                      <input type="file" className="sr-only" accept={CLAIM_FILE_ACCEPT} disabled={rowBusy === c.id} onChange={(e) => { void attach(c.id, e.target.files?.[0], c.evidence_path); e.target.value = '' }} />
                    </label>
                    {c.evidence_path && (
                      <button type="button" className="btn btn-ghost text-sm" disabled={rowBusy === c.id} onClick={() => void remove(c.id, c.evidence_path!)}>
                        Remove
                      </button>
                    )}
                  </span>
                )}
              </td>
              <td className="space-y-1">
                {data.reviews
                  .filter((r) => r.claim_id === c.id)
                  .map((r) => (
                    <p key={r.enterprise?.name ?? r.reviewed_at} className="text-sm">
                      <span className="font-medium">{r.enterprise?.name ?? 'An Enterprise'}:</span> {r.decision === 'accepted' ? 'accepted' : 'rejected'}
                      {r.note ? ` · ${r.note}` : ''}
                    </p>
                  ))}
              </td>
            </tr>
          ))}
          {data.claims.length === 0 && (
            <tr>
              <td colSpan={6} className="text-ink-2">
                Nothing yet. Start with Companies House and insurance.
              </td>
            </tr>
          )}
        </Table>
      </Section>
      <form onSubmit={submit} className="card max-w-xl space-y-4 p-5">
        <h2 className="text-xl">Send something to check</h2>
        <Field label="What" htmlFor="kind">
          <select id="kind" className="field" value={kind} onChange={(e) => setKind(e.target.value as ClaimKind)}>
            {kinds.map((k) => (
              <option key={k.value} value={k.value}>
                {k.text}
              </option>
            ))}
          </select>
        </Field>
        <Field label="Reference" htmlFor="ref" hint={kinds.find((k) => k.value === kind)?.hint}>
          <input id="ref" required className="field" value={reference} onChange={(e) => setReference(e.target.value)} />
        </Field>
        <Field label="Valid until (if it expires)" htmlFor="until">
          <input id="until" type="date" className="field" value={validUntil} onChange={(e) => setValidUntil(e.target.value)} />
        </Field>
        <Field label="Document (optional)" htmlFor="doc" hint="The certificate or letter behind it: a PDF or photo, up to 10 MB. The people who check it can open it.">
          <input key={fileKey} id="doc" type="file" className="field py-2" accept={CLAIM_FILE_ACCEPT} onChange={(e) => setFile(e.target.files?.[0] ?? null)} />
        </Field>
        <Field label="Notes for Duly" htmlFor="notes">
          <textarea id="notes" className="field min-h-[72px] py-2" value={notes} onChange={(e) => setNotes(e.target.value)} />
        </Field>
        <ErrorNote message={formError} />
        <button className="btn btn-primary" disabled={busy}>
          Send for checking
        </button>
      </form>
    </div>
  )
}
