import { useState } from 'react'
import { label } from '#/lib/format'
import { supabase } from '#/lib/supabase'
import { ErrorNote } from './ui'

export type CrewMember = { user_id: string; email: string; full_name: string | null; role: string }
export type Assigned = { user_id: string; role: string }

/** Who is on a visit, with the means to add or remove a cleaner. Shared by Jobs and crew and by the Dispatch board. */
export function AssignCrew({ jobId, assigned, members, onChange }: { jobId: string; assigned: Assigned[]; members: CrewMember[]; onChange: () => void }) {
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
            <button className="text-xs font-semibold text-alert" onClick={() => void unassign(a.user_id)} aria-label="Remove">
              ✕
            </button>
          </span>
        ))}
        {assigned.length === 0 && <span className="text-sm text-alert">No cleaner assigned yet</span>}
      </div>
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
      </div>
      <ErrorNote message={error} />
    </div>
  )
}
