import { createFileRoute } from '@tanstack/react-router'
import { useState } from 'react'
import { TeamManager } from '#/components/TeamManager'
import { ErrorNote, Loading } from '#/components/ui'
import type { Database } from '#/lib/database.types'
import { label, must, useLoad } from '#/lib/format'
import { supabase } from '#/lib/supabase'

export const Route = createFileRoute('/admin/people')({ component: AdminPeople })

type Role = Database['public']['Enums']['member_role']
const rolesFor: Record<string, Role[]> = {
  vendor: ['vendor_admin', 'dispatcher', 'operative'],
  buyer: ['owner', 'approver', 'viewer'],
  platform: ['platform_admin'],
}

function AdminPeople() {
  const { data, error, reload } = useLoad(
    async () => must(await supabase().from('organisations').select('id, name, kind, segment, verification_tier').order('kind').order('name')),
    [],
  )
  const [selected, setSelected] = useState<string>('')
  const [name, setName] = useState('')
  const [busy, setBusy] = useState(false)
  const [formError, setFormError] = useState<string | null>(null)

  async function addVendor() {
    setBusy(true)
    setFormError(null)
    const db = supabase()
    const { data: org, error: err } = await db.from('organisations').insert({ kind: 'vendor', name: name.trim(), segment: 'sme' }).select('id').single()
    if (!err && org) await db.from('vendor_profiles').insert({ org_id: org.id })
    setBusy(false)
    if (err) return setFormError(err.message)
    setName('')
    reload()
    if (org) setSelected(org.id)
  }

  if (error) return <ErrorNote message={error} />
  if (!data) return <Loading />
  const org = data.find((o) => o.id === selected)

  return (
    <div className="space-y-6">
      <h1 className="text-3xl">Organisations and people</h1>
      <div className="grid gap-6 lg:grid-cols-[320px_1fr]">
        <div className="space-y-3">
          <ul className="card max-h-[60vh] divide-y divide-line overflow-y-auto">
            {data.map((o) => (
              <li key={o.id}>
                <button
                  className={`flex min-h-[44px] w-full items-center justify-between gap-2 px-4 py-2 text-left text-sm ${selected === o.id ? 'bg-tint' : ''}`}
                  onClick={() => setSelected(o.id)}
                >
                  <span className="font-medium">{o.name}</span>
                  <span className="text-xs text-ink-2">{label(o.kind)}</span>
                </button>
              </li>
            ))}
          </ul>
          <div className="card space-y-2 p-4">
            <p className="text-sm font-semibold">Onboard a vendor</p>
            <input className="field" placeholder="Company name" value={name} onChange={(e) => setName(e.target.value)} />
            <button className="btn btn-ghost w-full" disabled={busy || !name.trim()} onClick={() => void addVendor()}>
              Create vendor
            </button>
            <ErrorNote message={formError} />
          </div>
        </div>
        <div>
          {org ? (
            <div className="space-y-4">
              <h2 className="text-2xl">{org.name}</h2>
              <TeamManager
                key={org.id}
                orgId={org.id}
                roles={rolesFor[org.kind] ?? []}
                canAdd
                hint="They need to have signed in to Duly once with this email."
              />
            </div>
          ) : (
            <p className="text-ink-2">Choose an organisation to see and add its people.</p>
          )}
        </div>
      </div>
    </div>
  )
}
