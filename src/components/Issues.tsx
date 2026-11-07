import { useEffect, useState } from 'react'
import type { FormEvent } from 'react'
import type { Database } from '#/lib/database.types'
import { label } from '#/lib/format'
import { supabase } from '#/lib/supabase'
import { Badge, ErrorNote, Field, Section } from './ui'

type IssueKind = Database['public']['Enums']['issue_kind']

const issueKinds: { value: IssueKind; text: string }[] = [
  { value: 'quality', text: 'Something wasn’t cleaned properly' },
  { value: 'damage', text: 'Damage or breakage' },
  { value: 'no_show', text: 'No one turned up' },
  { value: 'access', text: 'Access or keys problem' },
  { value: 'conduct', text: 'Cleaner’s behaviour' },
  { value: 'safeguarding', text: 'Safety or safeguarding concern (private)' },
  { value: 'other', text: 'Something else' },
]

type IssueRow = {
  id: string
  kind: string
  description: string
  status: string
  resolution: string | null
  created_at: string
  raised_by: string
  plan_label?: string | null
}

/** A cleaning area from the work schedule that a problem is about. */
export type IssueArea = { id: string; label: string }

export function Issues({ jobId, issues, me, onChange, area, onArea }: { jobId: string; issues: IssueRow[]; me?: string; onChange: () => void; area?: IssueArea | null; onArea?: (a: IssueArea | null) => void }) {
  const [kind, setKind] = useState<IssueKind>('quality')
  const [description, setDescription] = useState('')
  const [open, setOpen] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  // Choosing "Report a problem" on a cleaning area in the work schedule opens the form about that area.
  useEffect(() => {
    if (area) {
      setOpen(true)
      // Wait for the form to render, then bring it into view so the person sees which area it is about.
      requestAnimationFrame(() => document.getElementById('problem-form')?.scrollIntoView({ behavior: 'smooth', block: 'center' }))
    }
  }, [area?.id])

  async function submit(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError(null)
    const { data: user } = await supabase().auth.getUser()
    const { error: err } = await supabase()
      .from('issues')
      .insert({ job_id: jobId, kind, description: description.trim(), raised_by: user.user?.id ?? '', plan_item_id: area?.id ?? null })
    setBusy(false)
    if (err) return setError(err.message)
    setDescription('')
    setOpen(false)
    onArea?.(null)
    onChange()
  }

  async function resolve(id: string) {
    // Keep any outcome Duly or the vendor already recorded: marking it sorted must not overwrite that evidence.
    const existing = issues.find((i) => i.id === id)?.resolution
    const { error: err } = await supabase().from('issues').update({ status: 'resolved', resolution: existing || 'Resolved by the client' }).eq('id', id)
    if (err) setError(err.message)
    onChange()
  }

  return (
    <Section
      id="problems"
      title="Problems"
      action={
        !open && (
          <button className="btn btn-ghost text-sm" onClick={() => setOpen(true)}>
            Report a problem
          </button>
        )
      }
    >
      {issues.map((i) => (
        <div key={i.id} className="card space-y-1 p-4 text-sm">
          <div className="flex items-center justify-between gap-2">
            <p className="font-semibold">{label(i.kind)}</p>
            <Badge value={i.status} />
          </div>
          {i.plan_label && <p className="text-xs font-medium text-ink-2">About: {i.plan_label}</p>}
          <p>{i.description}</p>
          {i.resolution && <p className="text-ink-2">Outcome: {i.resolution}</p>}
          {i.status !== 'resolved' && i.raised_by === me && (
            <button className="btn btn-ghost mt-2 text-xs" onClick={() => void resolve(i.id)}>
              It’s sorted: mark resolved
            </button>
          )}
        </div>
      ))}
      {issues.length === 0 && !open && <p className="text-sm text-ink-2">No problems reported. Reporting one holds the payment until it’s sorted.</p>}
      {open && (
        <form id="problem-form" onSubmit={submit} className="card space-y-3 p-4">
          {area && (
            <div className="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-tint p-3 text-sm">
              <p>
                <span className="font-semibold">About:</span> {area.label}
              </p>
              <button type="button" className="link-action font-semibold text-primary" onClick={() => onArea?.(null)}>
                Not about one area
              </button>
            </div>
          )}
          <Field label="What kind of problem?" htmlFor="kind">
            <select id="kind" className="field" value={kind} onChange={(e) => setKind(e.target.value as IssueKind)}>
              {issueKinds.map((k) => (
                <option key={k.value} value={k.value}>
                  {k.text}
                </option>
              ))}
            </select>
          </Field>
          <Field label="What happened?" htmlFor="desc">
            <textarea id="desc" required className="field min-h-[96px] py-2" value={description} onChange={(e) => setDescription(e.target.value)} />
          </Field>
          <ErrorNote message={error} />
          <div className="flex gap-2">
            <button className="btn btn-primary" disabled={busy}>
              Send report
            </button>
            <button type="button" className="btn btn-ghost" onClick={() => setOpen(false)}>
              Cancel
            </button>
          </div>
        </form>
      )}
    </Section>
  )
}
