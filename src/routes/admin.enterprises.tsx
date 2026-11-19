import { createFileRoute } from '@tanstack/react-router'
import { useState } from 'react'
import type { FormEvent } from 'react'
import { Empty } from '#/components/Shells'
import { Badge, ErrorNote, Field, Loading, Section, Table } from '#/components/ui'
import { day, must, useLoad } from '#/lib/format'
import { supabase } from '#/lib/supabase'

export const Route = createFileRoute('/admin/enterprises')({ component: AdminEnterprises })

function AdminEnterprises() {
  const { data, error, reload } = useLoad(async () => {
    const db = supabase()
    const [orgs, roster] = await Promise.all([
      db.from('organisations').select('id, name, kind, segment, created_at').or('segment.eq.enterprise,kind.eq.vendor').order('name'),
      db
        .from('enterprise_vendors')
        .select('enterprise_org_id, vendor_org_id, status, note, created_at, enterprise:organisations!enterprise_vendors_enterprise_org_id_fkey(name), vendor:organisations!enterprise_vendors_vendor_org_id_fkey(name)')
        .order('created_at'),
    ])
    const all = must(orgs)
    return { enterprises: all.filter((o) => o.kind === 'buyer' && o.segment === 'enterprise'), vendors: all.filter((o) => o.kind === 'vendor'), roster: must(roster) }
  }, [])
  const [message, setMessage] = useState<string | null>(null)
  const [actionError, setActionError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  async function run(f: () => PromiseLike<{ error: { message: string } | null }>, done: string) {
    setBusy(true)
    setActionError(null)
    setMessage(null)
    const { error: err } = await f()
    setBusy(false)
    if (err) return setActionError(err.message)
    setMessage(done)
    reload()
  }

  if (error) return <ErrorNote message={error} />
  if (!data) return <Loading />

  return (
    <div className="space-y-8">
      <div>
        <h1 className="text-3xl">Enterprises</h1>
        <p className="mt-1 max-w-2xl text-sm text-ink-2">
          Set up an Enterprise and its vendors, and put each vendor on the Enterprise's roster. The Enterprise then accepts a vendor onto its roster before it can appoint it. People need an account first: ask them to sign in once.
        </p>
      </div>
      <ErrorNote message={actionError} />
      {message && <p className="rounded-lg bg-tint p-3 text-sm text-primary">{message}</p>}

      <div className="grid gap-4 lg:grid-cols-3">
        <CreateForm
          title="New Enterprise"
          first="Name"
          second="Owner's email"
          busy={busy}
          onSubmit={(a, b) => run(() => supabase().rpc('admin_create_enterprise', { p_name: a, p_owner_email: b }), `Created ${a}.`)}
        />
        <CreateForm
          title="New vendor"
          first="Name"
          second="Admin's email"
          busy={busy}
          onSubmit={(a, b) => run(() => supabase().rpc('admin_create_vendor', { p_name: a, p_admin_email: b }), `Created ${a}.`)}
        />
        <AddToRoster enterprises={data.enterprises} vendors={data.vendors} busy={busy} onAdd={(e, v, note) => run(() => supabase().rpc('enterprise_add_vendor', { p_enterprise: e, p_vendor: v, p_note: note || undefined }), 'Added to the roster.')} />
      </div>

      <Section title="Enterprises">
        {data.enterprises.length === 0 ? (
          <Empty title="No Enterprises yet">Create the first one above.</Empty>
        ) : (
          <Table head={['Enterprise', 'Vendors on roster', 'Created']}>
            {data.enterprises.map((e) => (
              <tr key={e.id}>
                <td className="font-semibold">{e.name}</td>
                <td>{data.roster.filter((r) => r.enterprise_org_id === e.id).length}</td>
                <td>{day(e.created_at)}</td>
              </tr>
            ))}
          </Table>
        )}
      </Section>

      <Section title="Rosters">
        {data.roster.length === 0 ? (
          <Empty title="No vendors on any roster yet" />
        ) : (
          <Table head={['Enterprise', 'Vendor', 'Status', 'Note']}>
            {data.roster.map((r) => (
              <tr key={`${r.enterprise_org_id}-${r.vendor_org_id}`}>
                <td>{r.enterprise?.name}</td>
                <td>{r.vendor?.name}</td>
                <td>
                  <Badge value={r.status} />
                </td>
                <td className="text-ink-2">{r.note ?? ''}</td>
              </tr>
            ))}
          </Table>
        )}
      </Section>
    </div>
  )
}

function CreateForm({ title, first, second, busy, onSubmit }: { title: string; first: string; second: string; busy: boolean; onSubmit: (a: string, b: string) => Promise<void> }) {
  const [a, setA] = useState('')
  const [b, setB] = useState('')
  async function submit(e: FormEvent) {
    e.preventDefault()
    await onSubmit(a.trim(), b.trim())
    setA('')
    setB('')
  }
  const id = title.replace(/\s+/g, '-').toLowerCase()
  return (
    <form onSubmit={submit} className="card space-y-3 p-4">
      <h2 className="text-lg">{title}</h2>
      <Field label={first} htmlFor={`${id}-a`}>
        <input id={`${id}-a`} required className="field" value={a} onChange={(e) => setA(e.target.value)} />
      </Field>
      <Field label={second} htmlFor={`${id}-b`}>
        <input id={`${id}-b`} required type="email" className="field" value={b} onChange={(e) => setB(e.target.value)} />
      </Field>
      <button className="btn btn-primary w-full" disabled={busy || !a.trim() || !b.trim()}>
        Create
      </button>
    </form>
  )
}

function AddToRoster({ enterprises, vendors, busy, onAdd }: { enterprises: { id: string; name: string }[]; vendors: { id: string; name: string }[]; busy: boolean; onAdd: (e: string, v: string, note: string) => Promise<void> }) {
  const [e, setE] = useState('')
  const [v, setV] = useState('')
  const [note, setNote] = useState('')
  async function submit(ev: FormEvent) {
    ev.preventDefault()
    await onAdd(e, v, note.trim())
    setNote('')
  }
  return (
    <form onSubmit={submit} className="card space-y-3 p-4">
      <h2 className="text-lg">Add a vendor to a roster</h2>
      <Field label="Enterprise" htmlFor="roster-enterprise">
        <select id="roster-enterprise" required className="field" value={e} onChange={(x) => setE(x.target.value)}>
          <option value="">Choose…</option>
          {enterprises.map((o) => (
            <option key={o.id} value={o.id}>
              {o.name}
            </option>
          ))}
        </select>
      </Field>
      <Field label="Vendor" htmlFor="roster-vendor">
        <select id="roster-vendor" required className="field" value={v} onChange={(x) => setV(x.target.value)}>
          <option value="">Choose…</option>
          {vendors.map((o) => (
            <option key={o.id} value={o.id}>
              {o.name}
            </option>
          ))}
        </select>
      </Field>
      <Field label="Note (optional)" htmlFor="roster-note">
        <input id="roster-note" className="field" value={note} onChange={(x) => setNote(x.target.value)} />
      </Field>
      <button className="btn btn-primary w-full" disabled={busy || !e || !v}>
        Add to roster
      </button>
    </form>
  )
}
