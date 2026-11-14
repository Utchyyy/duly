import { useState } from 'react'
import { label } from '#/lib/format'
import { supabase } from '#/lib/supabase'
import { ErrorNote } from './ui'

export type CrewMember = { user_id: string; email: string; full_name: string | null; role: string }
export type Assigned = { user_id: string; role: string }

/** Who is on a visit, with the means to add or remove a cleaner. Shared by Jobs and crew and by the Dispatch board. */
/**
 * `quietEmpty` leaves out the "no cleaner" note (the caller already says it). `collapsible` shows only who is on the visit
 * with a button to open the picker, which keeps a long list short; `startOpen` opens it at first, for a visit that needs a cleaner now.
 */
export function AssignCrew({
  jobId,
  assigned,
  members,
  onChange,
  quietEmpty = false,
  collapsible = false,
  startOpen = false,
}: {
  jobId: string
  assigned: Assigned[]
  members: CrewMember[]
  onChange: () => void
  quietEmpty?: boolean
  collapsible?: boolean
  startOpen?: boolean
}) {
  const [open, setOpen] = useState(!collapsible || startOpen)
  const [pick, setPick] = useState('')
  const [error, setError] = useState<string | null>(null)
  const name = (id: string) => {
    const m = members.find((x) => x.user_id === id)
    return m ? m.full_name || m.email : 'Unknown'
  }
  const on = new Set(assigned.map((a) => a.user_id))
  const people = Array.from(new Map(members.map((m) => [m.user_id, m])).values()).filter((m) => !on.has(m.user_id))

  async function assign() {
    if (!pick) return
    setError(null)
    const { error: err } = await supabase().from('job_assignments').insert({ job_id: jobId, user_id: pick, role: assigned.length === 0 ? 'lead' : 'crew' })
    if (err) setError(err.message)
    setPick('')
    if (collapsible && !err) setOpen(false)
    onChange()
  }

  async function unassign(userId: string) {
    const { error: err } = await supabase().from('job_assignments').delete().eq('job_id', jobId).eq('user_id', userId)
    if (err) setError(err.message)
    onChange()
  }

  return (
    <div className="space-y-2">
      <div className="flex flex-wrap gap-2">
        {assigned.map((a) => (
          <span key={a.user_id} className="inline-flex items-center gap-2 rounded-full bg-tint px-3 py-1 text-sm text-primary">
            {name(a.user_id)} · {label(a.role)}
            {/* A 44px hit area that does not make the chip taller. */}
            <button
              className="-my-3 -mr-2 inline-flex min-h-[44px] min-w-[44px] items-center justify-center text-xs font-semibold text-alert"
              onClick={() => void unassign(a.user_id)}
              aria-label={`Remove ${name(a.user_id)}`}
            >
              ✕
            </button>
          </span>
        ))}
        {assigned.length === 0 && !quietEmpty && <span className="text-sm text-alert">No cleaner assigned yet</span>}
      </div>
      {open ? (
        <div className="flex flex-wrap gap-2">
          <select className="field w-auto min-w-[14rem]" value={pick} onChange={(e) => setPick(e.target.value)} aria-label="Cleaner">
            <option value="">Choose a team member…</option>
            {people.map((m) => (
              <option key={m.user_id} value={m.user_id}>
                {m.full_name || m.email} ({label(m.role)})
              </option>
            ))}
          </select>
          <button className="btn btn-ghost" disabled={!pick} onClick={() => void assign()}>
            Assign
          </button>
          {collapsible && (
            <button className="btn btn-ghost" onClick={() => setOpen(false)}>
              Done
            </button>
          )}
        </div>
      ) : (
        <button className="btn btn-ghost text-sm" onClick={() => setOpen(true)}>
          Add or change cleaner
        </button>
      )}
      <ErrorNote message={error} />
    </div>
  )
}
