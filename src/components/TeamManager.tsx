import { useState } from 'react'
import type { FormEvent } from 'react'
import type { Database } from '#/lib/database.types'
import { label, must, useLoad } from '#/lib/format'
import { supabase } from '#/lib/supabase'
import { ErrorNote, Field, Loading, Table } from './ui'

type Role = Database['public']['Enums']['member_role']

/** People in an organisation, with an add-by-email form. */
export function TeamManager({ orgId, roles, canAdd, hint }: { orgId: string; roles: Role[]; canAdd: boolean; hint: string }) {
  const { data, error, reload } = useLoad(async () => must(await supabase().rpc('org_member_emails', { p_org: orgId })), [orgId])
  const [email, setEmail] = useState('')
  const [role, setRole] = useState<Role>(roles[0])
  const [busy, setBusy] = useState(false)
  const [formError, setFormError] = useState<string | null>(null)
  const [added, setAdded] = useState<string | null>(null)

  async function add(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setFormError(null)
    setAdded(null)
    const { error: err } = await supabase().rpc('add_member', { p_email: email.trim(), p_org: orgId, p_role: role })
    setBusy(false)
    if (err) return setFormError(err.message)
    setAdded(email.trim())
    setEmail('')
    reload()
  }

  return (
    <div className="space-y-6">
      <ErrorNote message={error} />
      {!data ? (
        <Loading />
      ) : (
        <Table head={['Name', 'Email', 'Role']}>
          {data.map((m) => (
            <tr key={`${m.user_id}-${m.role}`}>
              <td>{m.full_name ?? '–'}</td>
              <td>{m.email}</td>
              <td>{label(m.role)}</td>
            </tr>
          ))}
        </Table>
      )}
      {canAdd && (
        <form onSubmit={add} className="card max-w-xl space-y-4 p-5">
          <h2 className="text-xl">Add someone</h2>
          <p className="text-sm text-ink-2">{hint}</p>
          <Field label="Their email" htmlFor="member-email">
            <input id="member-email" type="email" required className="field" value={email} onChange={(e) => setEmail(e.target.value)} />
          </Field>
          <Field label="Role" htmlFor="member-role">
            <select id="member-role" className="field" value={role} onChange={(e) => setRole(e.target.value as Role)}>
              {roles.map((r) => (
                <option key={r} value={r}>
                  {label(r)}
                </option>
              ))}
            </select>
          </Field>
          <ErrorNote message={formError} />
          {added && <p className="rounded-lg bg-tint p-3 text-sm text-primary">Added {added}.</p>}
          <button className="btn btn-primary" disabled={busy}>
            Add
          </button>
        </form>
      )}
    </div>
  )
}
