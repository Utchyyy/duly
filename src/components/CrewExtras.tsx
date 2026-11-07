import { useState } from 'react'
import type { FormEvent } from 'react'
import type { Database } from '#/lib/database.types'
import { day, label, money, must, useLoad } from '#/lib/format'
import { supabase } from '#/lib/supabase'
import { Badge, ErrorNote, Field, Loading, Section } from './ui'

/** Shift offers from WFX and the worker's own upcoming shifts. */
export function ShiftOffers() {
  const { data, error, reload } = useLoad(async () => {
    const db = supabase()
    const { data: me } = await db.auth.getUser()
    const worker = must(await db.from('workers').select('id').eq('user_id', me.user?.id ?? '').single())
    const shifts = must(
      await db
        .from('shifts')
        .select('id, shift_date, start_time, end_time, hourly_pay, status, filled_by, town:towns(name), vendor:organisations(name), shift_events(worker_id, event_type)')
        .gte('shift_date', new Date().toLocaleDateString('en-CA'))
        .order('shift_date'),
    )
    return { workerId: worker.id, shifts }
  }, [])
  const [actionError, setActionError] = useState<string | null>(null)

  async function respond(id: string, accept: boolean) {
    setActionError(null)
    const { error: err } = await supabase().rpc('respond_to_shift', { p_shift: id, p_accept: accept })
    if (err) setActionError(err.message)
    reload()
  }

  if (error) return null
  if (!data) return <Loading />
  const mine = data.shifts.filter((s) => s.filled_by === data.workerId)
  const offers = data.shifts.filter(
    (s) =>
      s.filled_by === null &&
      ['open', 'offered'].includes(s.status) &&
      s.shift_events.some((e) => e.worker_id === data.workerId && e.event_type === 'offered') &&
      !s.shift_events.some((e) => e.worker_id === data.workerId && e.event_type === 'declined'),
  )
  if (mine.length === 0 && offers.length === 0) return null

  return (
    <Section title="Shifts">
      <ErrorNote message={actionError} />
      {offers.map((s) => (
        <div key={s.id} className="card space-y-3 border-primary p-4">
          <div>
            <p className="font-semibold">
              {day(s.shift_date)} · {s.start_time.slice(0, 5)}–{s.end_time.slice(0, 5)}
            </p>
            <p className="text-sm text-ink-2">
              {s.vendor?.name} · {s.town?.name} · {money(s.hourly_pay)}/h
            </p>
          </div>
          <div className="flex gap-2">
            <button className="btn btn-primary flex-1" onClick={() => void respond(s.id, true)}>
              Accept
            </button>
            <button className="btn btn-ghost flex-1" onClick={() => void respond(s.id, false)}>
              Can't do it
            </button>
          </div>
        </div>
      ))}
      {mine.map((s) => (
        <div key={s.id} className="card flex items-center justify-between gap-3 p-4">
          <div>
            <p className="font-semibold">
              {day(s.shift_date)} · {s.start_time.slice(0, 5)}–{s.end_time.slice(0, 5)}
            </p>
            <p className="text-sm text-ink-2">
              {s.vendor?.name} · {s.town?.name}
            </p>
          </div>
          <Badge value="accepted">Yours</Badge>
        </div>
      ))}
    </Section>
  )
}

type CertType = Database['public']['Enums']['dbs_certificate_type']

/** The worker's DBS checks: start a new check or register an existing certificate on the Update Service. */
export function MyChecks() {
  const { data, error, reload } = useLoad(async () => {
    const db = supabase()
    const { data: me } = await db.auth.getUser()
    const worker = must(await db.from('workers').select('id, dbs_cleared').eq('user_id', me.user?.id ?? '').single())
    const apps = must(await db.from('dbs_applications').select('id, path, status, certificate_type, created_at').eq('worker_id', worker.id).order('created_at'))
    return { worker, apps }
  }, [])
  const [path, setPath] = useState<'new_check' | 'existing_certificate'>('new_check')
  const [certType, setCertType] = useState<CertType>('enhanced')
  const [reference, setReference] = useState('')
  const [updateId, setUpdateId] = useState('')
  const [open, setOpen] = useState(false)
  const [busy, setBusy] = useState(false)
  const [formError, setFormError] = useState<string | null>(null)

  async function submit(e: FormEvent) {
    e.preventDefault()
    if (!data) return
    setBusy(true)
    setFormError(null)
    const existing = path === 'existing_certificate'
    const { error: err } = await supabase()
      .from('dbs_applications')
      .insert({
        worker_id: data.worker.id,
        path,
        certificate_type: existing ? certType : null,
        certificate_reference: existing ? reference.trim() : null,
        update_service_id: existing ? updateId.trim() : null,
      })
    setBusy(false)
    if (err) return setFormError(err.message)
    setOpen(false)
    reload()
  }

  if (error) return null
  if (!data) return <Loading />
  const pending = data.apps.some((a) => ['submitted_by_worker', 'sent_to_ucheck'].includes(a.status))

  return (
    <Section title="Your checks">
      <div className="card space-y-2 p-4 text-sm">
        <p>
          DBS: {data.worker.dbs_cleared ? <Badge value="verified">Cleared</Badge> : pending ? <Badge value="pending">In progress</Badge> : <Badge value="open">Not checked</Badge>}
        </p>
        {data.apps.map((a) => (
          <p key={a.id} className="text-ink-2">
            {a.path === 'new_check' ? 'New check' : `Existing ${label(a.certificate_type ?? '')} certificate`} · {label(a.status)} · {day(a.created_at)}
          </p>
        ))}
        {!data.worker.dbs_cleared && !pending && !open && (
          <button className="btn btn-ghost mt-2" onClick={() => setOpen(true)}>
            Start a DBS check
          </button>
        )}
      </div>
      {open && (
        <form onSubmit={submit} className="card space-y-3 p-4">
          <Field label="Do you already have a DBS certificate on the Update Service?" htmlFor="dbs-path">
            <select id="dbs-path" className="field" value={path} onChange={(e) => setPath(e.target.value as typeof path)}>
              <option value="new_check">No: start a new check</option>
              <option value="existing_certificate">Yes: use my existing certificate</option>
            </select>
          </Field>
          {path === 'existing_certificate' && (
            <>
              <Field label="Certificate level" htmlFor="dbs-type">
                <select id="dbs-type" className="field" value={certType} onChange={(e) => setCertType(e.target.value as CertType)}>
                  <option value="enhanced">Enhanced</option>
                  <option value="standard">Standard</option>
                </select>
              </Field>
              <Field label="Certificate number" htmlFor="dbs-ref">
                <input id="dbs-ref" required className="field" value={reference} onChange={(e) => setReference(e.target.value)} />
              </Field>
              <Field label="Update Service ID" htmlFor="dbs-us" hint="Duly checks the certificate's status online with your permission.">
                <input id="dbs-us" required className="field" value={updateId} onChange={(e) => setUpdateId(e.target.value)} />
              </Field>
            </>
          )}
          {path === 'new_check' && <p className="text-sm text-ink-2">Duly will contact you to verify your ID and start the check. There's no charge to you.</p>}
          <ErrorNote message={formError} />
          <div className="flex gap-2">
            <button className="btn btn-primary" disabled={busy}>
              Send
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
