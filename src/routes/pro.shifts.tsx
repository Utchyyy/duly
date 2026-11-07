import { createFileRoute } from '@tanstack/react-router'
import { useState } from 'react'
import type { FormEvent } from 'react'
import { Empty } from '#/components/Shells'
import { Badge, ErrorNote, Field, Loading, Section } from '#/components/ui'
import { day, money, must, useLoad, when } from '#/lib/format'
import { supabase } from '#/lib/supabase'
import { useVendor } from '#/lib/vendor'

export const Route = createFileRoute('/pro/shifts')({ component: ProShifts })

function ProShifts() {
  const vendor = useVendor()!
  const { data, error, reload } = useLoad(async () => {
    const db = supabase()
    const today = new Date().toISOString().slice(0, 10)
    const [towns, shifts, jobs, org] = await Promise.all([
      db.from('towns').select('id, name').order('name'),
      db
        .from('shifts')
        .select('id, shift_date, start_time, end_time, hourly_pay, status, job_id, town:towns(name), worker:workers!shifts_filled_by_fkey(full_name), shift_events(worker_id, event_type)')
        .eq('vendor_org_id', vendor.id)
        .gte('shift_date', today)
        .order('shift_date')
        .order('start_time'),
      db
        .from('jobs')
        .select('id, scheduled_start, site:sites(name, town)')
        .eq('vendor_org_id', vendor.id)
        .in('status', ['matched', 'requested'])
        .gte('scheduled_start', new Date().toISOString())
        .order('scheduled_start')
        .limit(50),
      db.from('organisations').select('markets(currency, timezone)').eq('id', vendor.id).single(),
    ])
    return { towns: must(towns), shifts: must(shifts), jobs: must(jobs), currency: must(org).markets?.currency ?? 'GBP' }
  }, [vendor.id])

  if (error) return <ErrorNote message={error} />
  if (!data) return <Loading />

  return (
    <div className="space-y-8">
      <div>
        <h1 className="text-3xl">Shifts</h1>
        <p className="mt-1 text-ink-2">
          Short of a cleaner? Post a shift and Duly ranks screened workers from across the WFX pool by fit and travel. Travel bands
          set how many minutes of travel you pay.
        </p>
      </div>
      <NewShift vendorId={vendor.id} towns={data.towns} jobs={data.jobs} currency={data.currency} onDone={reload} />
      <Section title="Upcoming shifts">
        {data.shifts.length === 0 ? (
          <Empty title="No upcoming shifts">Post one above.</Empty>
        ) : (
          <div className="space-y-3">
            {data.shifts.map((s) => (
              <ShiftCard key={s.id} shift={s} currency={data.currency} onChange={reload} />
            ))}
          </div>
        )}
      </Section>
    </div>
  )
}

type Town = { id: number; name: string }
type JobOpt = { id: string; scheduled_start: string; site: { name: string; town: string | null } | null }

function NewShift({ vendorId, towns, jobs, currency, onDone }: { vendorId: string; towns: Town[]; jobs: JobOpt[]; currency: string; onDone: () => void }) {
  const [townId, setTownId] = useState<number | ''>('')
  const [date, setDate] = useState('')
  const [start, setStart] = useState('06:00')
  const [end, setEnd] = useState('08:00')
  const [pay, setPay] = useState('12.60')
  const [jobId, setJobId] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  function pickJob(id: string) {
    setJobId(id)
    const j = jobs.find((x) => x.id === id)
    if (j) {
      const d = new Date(j.scheduled_start)
      setDate(d.toLocaleDateString('en-CA'))
      setStart(d.toTimeString().slice(0, 5))
      const t = towns.find((x) => x.name.toLowerCase() === (j.site?.town ?? '').toLowerCase())
      if (t) setTownId(t.id)
    }
  }

  async function submit(e: FormEvent) {
    e.preventDefault()
    if (townId === '') return setError('Choose a town.')
    setBusy(true)
    setError(null)
    const { error: err } = await supabase()
      .from('shifts')
      .insert({ vendor_org_id: vendorId, town_id: townId, shift_date: date, start_time: start, end_time: end, hourly_pay: Number(pay), job_id: jobId || null })
    setBusy(false)
    if (err) return setError(err.message)
    setJobId('')
    onDone()
  }

  return (
    <form onSubmit={submit} className="card space-y-4 p-5">
      <h2 className="text-xl">Post a shift</h2>
      {jobs.length > 0 && (
        <Field label="For a booked job (optional)" htmlFor="job" hint="The worker who accepts is added to the job automatically.">
          <select id="job" className="field" value={jobId} onChange={(e) => pickJob(e.target.value)}>
            <option value="">Not linked to a job</option>
            {jobs.map((j) => (
              <option key={j.id} value={j.id}>
                {when(j.scheduled_start)} · {j.site?.name}, {j.site?.town}
              </option>
            ))}
          </select>
        </Field>
      )}
      <div className="grid gap-4 sm:grid-cols-3">
        <Field label="Town" htmlFor="town">
          <select id="town" className="field" required value={townId} onChange={(e) => setTownId(e.target.value ? Number(e.target.value) : '')}>
            <option value="">Choose…</option>
            {towns.map((t) => (
              <option key={t.id} value={t.id}>
                {t.name}
              </option>
            ))}
          </select>
        </Field>
        <Field label="Date" htmlFor="date">
          <input id="date" type="date" required className="field" value={date} onChange={(e) => setDate(e.target.value)} />
        </Field>
        <Field label={`Pay per hour (${currency})`} htmlFor="pay" hint="Only you and the worker see this.">
          <input id="pay" type="number" step="0.05" min="1" required className="field" value={pay} onChange={(e) => setPay(e.target.value)} />
        </Field>
        <Field label="Start" htmlFor="start">
          <input id="start" type="time" required className="field" value={start} onChange={(e) => setStart(e.target.value)} />
        </Field>
        <Field label="End" htmlFor="end">
          <input id="end" type="time" required className="field" value={end} onChange={(e) => setEnd(e.target.value)} />
        </Field>
      </div>
      <ErrorNote message={error} />
      <button className="btn btn-primary" disabled={busy}>
        Post shift
      </button>
    </form>
  )
}

type ShiftRow = {
  id: string
  shift_date: string
  start_time: string
  end_time: string
  hourly_pay: number
  status: string
  job_id: string | null
  town: { name: string } | null
  worker: { full_name: string } | null
  shift_events: { worker_id: string | null; event_type: string }[]
}
type Candidate = { worker_id: string; full_name: string; home_town: string; km: number; band: string; paid_minutes: number; note: string; wiix_score: number; rank_score: number; cross_town: boolean }

function ShiftCard({ shift, currency, onChange }: { shift: ShiftRow; currency: string; onChange: () => void }) {
  const [candidates, setCandidates] = useState<Candidate[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const offered = new Set(shift.shift_events.filter((e) => e.event_type === 'offered').map((e) => e.worker_id))
  const declined = new Set(shift.shift_events.filter((e) => e.event_type === 'declined').map((e) => e.worker_id))

  async function find() {
    setError(null)
    const { data, error: err } = await supabase().rpc('rank_candidates', { p_shift_id: shift.id })
    if (err) return setError(err.message)
    setCandidates((data ?? []) as Candidate[])
  }

  async function offer(workerId: string) {
    setError(null)
    const { error: err } = await supabase().rpc('offer_shift', { p_shift: shift.id, p_worker: workerId })
    if (err) return setError(err.message)
    onChange()
  }

  const open = shift.status === 'open' || shift.status === 'offered'

  return (
    <div className="card space-y-3 p-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p className="font-semibold">
            {day(shift.shift_date)} · {shift.start_time.slice(0, 5)}–{shift.end_time.slice(0, 5)} · {shift.town?.name}
          </p>
          <p className="text-sm text-ink-2">
            {money(shift.hourly_pay, currency)}/h{shift.job_id ? ' · linked to a job' : ''}
            {shift.worker ? ` · ${shift.worker.full_name}` : ''}
            {offered.size > 0 && open ? ` · offered to ${offered.size}` : ''}
          </p>
        </div>
        <Badge value={shift.status === 'filled' ? 'accepted' : shift.status}>{shift.status === 'filled' ? 'Filled' : undefined}</Badge>
      </div>
      {open && (
        <>
          {candidates === null ? (
            <button className="btn btn-ghost text-sm" onClick={() => void find()}>
              Find workers
            </button>
          ) : candidates.length === 0 ? (
            <p className="text-sm text-ink-2">No screened workers fit this shift's time and travel yet.</p>
          ) : (
            <ol className="divide-y divide-line rounded-xl border border-line">
              {candidates.map((c, i) => (
                <li key={c.worker_id} className="flex flex-wrap items-center justify-between gap-3 p-3 text-sm">
                  <div>
                    <p className="font-medium">
                      {i + 1}. {c.full_name} <span className="text-ink-2">from {c.home_town}</span>
                    </p>
                    <p className="text-ink-2">
                      {c.km} km · {c.band} · WIIx {c.wiix_score} · {c.note}
                    </p>
                  </div>
                  {declined.has(c.worker_id) ? (
                    <Badge value="declined" />
                  ) : offered.has(c.worker_id) ? (
                    <Badge value="submitted">Offered</Badge>
                  ) : (
                    <button className="btn btn-primary !min-h-[36px] text-xs" onClick={() => void offer(c.worker_id)}>
                      Offer
                    </button>
                  )}
                </li>
              ))}
            </ol>
          )}
        </>
      )}
      <ErrorNote message={error} />
    </div>
  )
}
