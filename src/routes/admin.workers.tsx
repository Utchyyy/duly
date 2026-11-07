import { createFileRoute } from '@tanstack/react-router'
import { useState } from 'react'
import { Badge, ErrorNote, Loading, Section } from '#/components/ui'
import type { Database } from '#/lib/database.types'
import { day, label, must, useLoad } from '#/lib/format'
import { supabase } from '#/lib/supabase'

export const Route = createFileRoute('/admin/workers')({ component: AdminWorkers })

type DbsStatus = Database['public']['Enums']['dbs_status']
const dbsStatuses: DbsStatus[] = ['submitted_by_worker', 'sent_to_ucheck', 'cleared', 'not_cleared', 'withdrawn']

function AdminWorkers() {
  const { data, error, reload } = useLoad(async () => {
    const db = supabase()
    const [workers, vendors, apps] = await Promise.all([
      db
        .from('workers')
        .select('id, full_name, phone, vendor_org_id, max_commute_km, available_early, available_evening, dbs_cleared, created_at, town:towns(name), wiix_screens(reliability, shift_fit, capability, commute_tolerance, wiix_score)')
        .order('created_at', { ascending: false }),
      db.from('organisations').select('id, name').eq('kind', 'vendor').order('name'),
      db.from('dbs_applications').select('id, worker_id, path, status, certificate_type, certificate_reference, update_service_id, admin_notes, created_at').order('created_at'),
    ])
    return { workers: must(workers), vendors: must(vendors), apps: must(apps) }
  }, [])

  if (error) return <ErrorNote message={error} />
  if (!data) return <Loading />
  const openApps = data.apps.filter((a) => ['submitted_by_worker', 'sent_to_ucheck'].includes(a.status))

  return (
    <div className="space-y-8">
      <div>
        <h1 className="text-3xl">Workers</h1>
        <p className="mt-1 text-ink-2">
          Workers join from Duly Crew. Screen them (WIIx) to enter the shift pool, process DBS checks, and attach them to a company.
          The WIIx score is calculated from the four ratings.
        </p>
      </div>
      {openApps.length > 0 && (
        <Section title={`DBS checks to process (${openApps.length})`}>
          {openApps.map((a) => (
            <DbsRow key={a.id} app={a} name={data.workers.find((w) => w.id === a.worker_id)?.full_name ?? 'Worker'} onChange={reload} />
          ))}
        </Section>
      )}
      <Section title={`All workers (${data.workers.length})`}>
        {data.workers.map((w) => (
          <WorkerRow key={w.id} worker={w} vendors={data.vendors} onChange={reload} />
        ))}
        {data.workers.length === 0 && <p className="text-ink-2">No workers yet.</p>}
      </Section>
    </div>
  )
}

type App = {
  id: string
  worker_id: string
  path: string
  status: DbsStatus
  certificate_type: string | null
  certificate_reference: string | null
  update_service_id: string | null
  admin_notes: string | null
  created_at: string
}

function DbsRow({ app, name, onChange }: { app: App; name: string; onChange: () => void }) {
  const [status, setStatus] = useState<DbsStatus>(app.status)
  const [notes, setNotes] = useState(app.admin_notes ?? '')
  const [error, setError] = useState<string | null>(null)
  async function save() {
    setError(null)
    const { error: err } = await supabase().from('dbs_applications').update({ status, admin_notes: notes.trim() || null }).eq('id', app.id)
    if (err) setError(err.message)
    onChange()
  }
  return (
    <div className="card space-y-2 p-4 text-sm">
      <p className="font-semibold">
        {name} · {app.path === 'new_check' ? 'New check' : `Existing ${label(app.certificate_type ?? '')} certificate`} · sent {day(app.created_at)}
      </p>
      {app.path === 'existing_certificate' && (
        <p className="text-ink-2">
          Certificate {app.certificate_reference} · Update Service ID {app.update_service_id}
        </p>
      )}
      <div className="flex flex-wrap gap-2">
        <select className="field w-auto" value={status} onChange={(e) => setStatus(e.target.value as DbsStatus)} aria-label="DBS status">
          {dbsStatuses.map((s) => (
            <option key={s} value={s}>
              {label(s)}
            </option>
          ))}
        </select>
        <input className="field min-w-[12rem] flex-1" placeholder="Notes (internal)" value={notes} onChange={(e) => setNotes(e.target.value)} />
        <button className="btn btn-primary" onClick={() => void save()}>
          Save
        </button>
      </div>
      <ErrorNote message={error} />
    </div>
  )
}

type WorkerRowData = {
  id: string
  full_name: string
  phone: string | null
  vendor_org_id: string | null
  max_commute_km: number
  available_early: boolean
  available_evening: boolean
  dbs_cleared: boolean
  created_at: string
  town: { name: string } | null
  wiix_screens: { reliability: number | null; shift_fit: number | null; capability: number | null; commute_tolerance: number | null; wiix_score: number } | null
}

const ratings = [
  { key: 'reliability', text: 'Reliability' },
  { key: 'shift_fit', text: 'Shift fit' },
  { key: 'capability', text: 'Capability' },
  { key: 'commute_tolerance', text: 'Travel' },
] as const

function WorkerRow({ worker, vendors, onChange }: { worker: WorkerRowData; vendors: { id: string; name: string }[]; onChange: () => void }) {
  const s = worker.wiix_screens
  const [r, setR] = useState({
    reliability: s?.reliability ?? 3,
    shift_fit: s?.shift_fit ?? 3,
    capability: s?.capability ?? 3,
    commute_tolerance: s?.commute_tolerance ?? 3,
  })
  const [open, setOpen] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function screen() {
    setError(null)
    const { error: err } = await supabase().from('wiix_screens').upsert({ worker_id: worker.id, ...r, wiix_score: 0 })
    if (err) return setError(err.message)
    setOpen(false)
    onChange()
  }

  async function attach(vendorId: string) {
    setError(null)
    const { error: err } = await supabase().from('workers').update({ vendor_org_id: vendorId || null }).eq('id', worker.id)
    if (err) setError(err.message)
    onChange()
  }

  return (
    <div className="card space-y-3 p-4 text-sm">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p className="font-semibold">{worker.full_name}</p>
          <p className="text-ink-2">
            {worker.town?.name} · travels up to {worker.max_commute_km} km
            {worker.available_early ? ' · early starts' : ''}
            {worker.available_evening ? ' · evenings' : ''} · joined {day(worker.created_at)}
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          {s ? <Badge value="verified">WIIx {s.wiix_score}</Badge> : <Badge value="open">Not screened</Badge>}
          {worker.dbs_cleared ? <Badge value="verified">DBS cleared</Badge> : <Badge value="pending">No DBS</Badge>}
        </div>
      </div>
      <div className="flex flex-wrap items-center gap-2">
        <select className="field w-auto" value={worker.vendor_org_id ?? ''} onChange={(e) => void attach(e.target.value)} aria-label="Company">
          <option value="">Freelance (no company)</option>
          {vendors.map((v) => (
            <option key={v.id} value={v.id}>
              {v.name}
            </option>
          ))}
        </select>
        <button className="btn btn-ghost" onClick={() => setOpen((x) => !x)}>
          {s ? 'Re-screen' : 'Screen'}
        </button>
      </div>
      {open && (
        <div className="grid gap-3 sm:grid-cols-5">
          {ratings.map((x) => (
            <label key={x.key} className="text-xs text-ink-2">
              {x.text} (1–5)
              <input
                type="number"
                min={1}
                max={5}
                className="field mt-1 !min-h-[40px] text-sm text-ink"
                value={r[x.key]}
                onChange={(e) => setR((v) => ({ ...v, [x.key]: Math.max(1, Math.min(5, Number(e.target.value))) }))}
              />
            </label>
          ))}
          <button className="btn btn-primary self-end" onClick={() => void screen()}>
            Save screen
          </button>
        </div>
      )}
      <ErrorNote message={error} />
    </div>
  )
}
