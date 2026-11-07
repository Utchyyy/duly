import { Link, createFileRoute, useNavigate } from '@tanstack/react-router'
import { useEffect, useState } from 'react'
import { Gate } from '#/components/Gate'
import { AppShell, Empty } from '#/components/Shells'
import { Badge, ErrorNote, Loading, Section } from '#/components/ui'
import type { Json } from '#/lib/database.types'
import { day, money, must, useLoad } from '#/lib/format'
import { hoursLabel, newId, parseSchedule, totalMinutes } from '#/lib/schedule'
import type { Schedule } from '#/lib/schedule'
import { supabase } from '#/lib/supabase'

export const Route = createFileRoute('/briefs/$briefId')({
  head: () => ({ meta: [{ title: 'Brief · Duly' }] }),
  component: BriefPage,
})

function BriefPage() {
  return (
    <AppShell wide>
      <Gate allowSignUp signInHeading="Sign in">
        <Brief />
      </Gate>
    </AppShell>
  )
}

type PriceLine = { area_id: string; name: string; minutes: number; amount: number }
type Price = { lines?: PriceLine[]; labour?: number; urgency_amount?: number; total?: number; hourly_rate?: number }

function Brief() {
  const { briefId } = Route.useParams()
  const { data, error, reload } = useLoad(async () => {
    const db = supabase()
    const brief = must(
      await db
        .from('briefs')
        .select('id, title, status, current_version, buyer_org_id, site:sites(id, name, town, postcode, lat), org:organisations(segment, market, markets(currency))')
        .eq('id', briefId)
        .single(),
    )
    const [version, quotes, library, contracts] = await Promise.all([
      db.from('brief_versions').select('version, schedule, notes, locked_at, preferred_days, preferred_start').eq('brief_id', briefId).eq('version', brief.current_version).single(),
      db
        .from('quotes')
        .select('id, status, total, currency, lines, valid_until, brief_version, vendor:organisations(id, name)')
        .eq('brief_id', briefId)
        .order('created_at'),
      db.from('standards_library').select('id, segment, area_type, text'),
      db.from('contracts').select('id, status, brief_version, billing, vendor:organisations!contracts_vendor_org_id_fkey(name)').eq('brief_id', briefId),
    ])
    return { brief, version: must(version), quotes: must(quotes), library: must(library), contracts: must(contracts) }
  }, [briefId])

  if (error) return <ErrorNote message={error} />
  if (!data) return <Loading />

  const { brief, version } = data
  const locked = Boolean(version.locked_at)
  const currency = brief.org?.markets?.currency ?? 'GBP'

  return (
    <div className="mx-auto max-w-3xl space-y-8">
      <div>
        <Link to={brief.org?.segment === 'homeowner' ? '/' : '/business'} className="text-sm font-medium text-primary">
          ← Back
        </Link>
        <div className="mt-2 flex flex-wrap items-center gap-3">
          <h1 className="text-3xl">{brief.title}</h1>
          <Badge value={locked ? 'locked' : 'draft'}>{locked ? `Locked · v${version.version}` : `Draft · v${version.version}`}</Badge>
        </div>
        <p className="mt-1 text-ink-2">
          {brief.site?.name} · {brief.site?.town} {brief.site?.postcode}
        </p>
      </div>

      {locked ? (
        <>
          <ScheduleView schedule={parseSchedule(version.schedule)} />
          <VisitsSummary days={version.preferred_days} start={version.preferred_start} notes={version.notes} />
          <Contracts contracts={data.contracts} hasPattern={Boolean(version.preferred_days?.length && version.preferred_start)} />
          <Vendors
            briefId={brief.id}
            version={version.version}
            siteId={brief.site?.id ?? ''}
            quotes={data.quotes}
            currency={currency}
            onChange={reload}
          />
          <Quotes
            quotes={data.quotes.filter((q) => q.brief_version === version.version)}
            currency={currency}
            hasPattern={Boolean(version.preferred_days?.length && version.preferred_start)}
          />
          <NewVersion briefId={brief.id} version={version.version} schedule={version.schedule} onDone={reload} />
        </>
      ) : (
        <Editor
          briefId={brief.id}
          version={version.version}
          initial={parseSchedule(version.schedule)}
          initialDays={version.preferred_days ?? []}
          initialStart={version.preferred_start?.slice(0, 5) ?? ''}
          initialNotes={version.notes ?? ''}
          library={data.library}
          segment={brief.org?.segment ?? 'homeowner'}
          onLocked={reload}
        />
      )}
    </div>
  )
}

function ScheduleView({ schedule }: { schedule: Schedule }) {
  return (
    <Section title={`Schedule · ${hoursLabel(totalMinutes(schedule))} per visit`}>
      {schedule.map((s) => (
        <div key={s.name} className="card divide-y divide-line">
          <p className="p-4 font-semibold">{s.name}</p>
          {s.areas.map((a) => (
            <div key={a.id} className="p-4">
              <div className="flex justify-between gap-3">
                <p className="font-medium">{a.name}</p>
                <p className="text-sm text-ink-2">{a.minutes} min</p>
              </div>
              <ul className="mt-1 list-disc space-y-0.5 pl-5 text-sm text-ink-2">
                {a.standards.map((st) => (
                  <li key={st.id}>{st.text}</li>
                ))}
              </ul>
            </div>
          ))}
        </div>
      ))}
    </Section>
  )
}

type Lib = { id: string; segment: string; area_type: string; text: string }

function Editor({
  briefId,
  version,
  initial,
  initialDays,
  initialStart,
  initialNotes,
  library,
  segment,
  onLocked,
}: {
  briefId: string
  version: number
  initial: Schedule
  initialDays: string[]
  initialStart: string
  initialNotes: string
  library: Lib[]
  segment: string
  onLocked: () => void
}) {
  const [schedule, setSchedule] = useState<Schedule>(initial.length ? initial : [{ name: 'Areas', areas: [] }])
  const [days, setDays] = useState<string[]>(initialDays)
  const [startTime, setStartTime] = useState(initialStart)
  const [notes, setNotes] = useState(initialNotes)
  const [dirty, setDirty] = useState(false)
  const [busy, setBusy] = useState(false)
  const [confirmLock, setConfirmLock] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const areaTypes = Array.from(new Set(library.map((l) => l.area_type))).sort()

  function update(fn: (s: Schedule) => Schedule) {
    setSchedule((s) => fn(structuredClone(s)))
    setDirty(true)
  }

  async function save(): Promise<boolean> {
    setBusy(true)
    setError(null)
    const { error: err } = await supabase()
      .from('brief_versions')
      .update({
        schedule: schedule as unknown as Json,
        preferred_days: days.length ? days : null,
        preferred_start: startTime || null,
        notes: notes.trim() || null,
      })
      .eq('brief_id', briefId)
      .eq('version', version)
    setBusy(false)
    if (err) {
      setError(err.message)
      return false
    }
    setDirty(false)
    return true
  }

  async function lock() {
    const areas = schedule.flatMap((s) => s.areas)
    if (areas.length === 0) return setError('Add at least one area first.')
    if (areas.some((a) => !a.minutes || a.minutes <= 0)) return setError('Every area needs a time in minutes.')
    if (areas.some((a) => a.standards.length === 0)) return setError('Every area needs at least one standard, so the clean can be checked.')
    if (days.length > 0 && !startTime) return setError('Add a start time for the regular visits.')
    if (!(await save())) return
    setBusy(true)
    const db = supabase()
    const { data: user } = await db.auth.getUser()
    const res = await db
      .from('brief_versions')
      .update({ locked_at: new Date().toISOString(), locked_by: user.user?.id ?? null })
      .eq('brief_id', briefId)
      .eq('version', version)
    if (!res.error) await db.from('briefs').update({ status: 'locked' }).eq('id', briefId)
    setBusy(false)
    if (res.error) return setError(res.error.message)
    onLocked()
  }

  return (
    <div className="space-y-6">
      <div className="card bg-tint/50 p-4 text-sm">
        Adjust the areas, minutes and standards until they match what you want done. When you lock the brief, it becomes the
        contract: vendors price exactly this, and the cleaner is checked against these standards.
      </div>
      {schedule.map((sec, si) => (
        <div key={si} className="card divide-y divide-line">
          <div className="flex items-center gap-2 p-4">
            <input
              className="field font-semibold"
              value={sec.name}
              aria-label="Section name"
              onChange={(e) => update((s) => ((s[si].name = e.target.value), s))}
            />
            <button
              type="button"
              className="btn btn-ghost shrink-0 text-sm"
              onClick={() => update((s) => s.filter((_, i) => i !== si))}
            >
              Remove
            </button>
          </div>
          {sec.areas.map((a, ai) => (
            <div key={a.id} className="space-y-2 p-4">
              <div className="flex flex-wrap items-center gap-2">
                <input
                  className="field min-w-[10rem] flex-1"
                  value={a.name}
                  aria-label="Area name"
                  onChange={(e) => update((s) => ((s[si].areas[ai].name = e.target.value), s))}
                />
                <label className="flex items-center gap-2 text-sm text-ink-2">
                  <input
                    type="number"
                    min={1}
                    max={600}
                    className="field w-24"
                    value={a.minutes || ''}
                    aria-label="Minutes"
                    onChange={(e) => update((s) => ((s[si].areas[ai].minutes = Number(e.target.value)), s))}
                  />
                  min
                </label>
                <button
                  type="button"
                  className="btn btn-ghost text-sm"
                  onClick={() => update((s) => ((s[si].areas = s[si].areas.filter((_, i) => i !== ai)), s))}
                >
                  Remove
                </button>
              </div>
              <ul className="space-y-1">
                {a.standards.map((st, sti) => (
                  <li key={st.id} className="flex items-start justify-between gap-2 text-sm">
                    <span className="text-ink-2">• {st.text}</span>
                    <button
                      type="button"
                      className="shrink-0 px-2 text-xs font-semibold text-alert"
                      onClick={() =>
                        update((s) => ((s[si].areas[ai].standards = s[si].areas[ai].standards.filter((_, i) => i !== sti)), s))
                      }
                    >
                      Remove
                    </button>
                  </li>
                ))}
              </ul>
              <AddStandard
                onAdd={(text) =>
                  update((s) => (s[si].areas[ai].standards.push({ id: newId(), text }), s))
                }
              />
            </div>
          ))}
          <AddArea
            areaTypes={areaTypes}
            onAdd={(name, minutes, areaType) =>
              update((s) => {
                const own = library.filter((l) => l.area_type === areaType && l.segment === segment)
                const pool = own.length ? own : library.filter((l) => l.area_type === areaType)
                s[si].areas.push({
                  id: newId(),
                  name,
                  minutes,
                  area_type: areaType || undefined,
                  standards: pool.map((l) => ({ id: l.id, text: l.text })),
                })
                return s
              })
            }
          />
        </div>
      ))}
      <button type="button" className="btn btn-ghost" onClick={() => update((s) => [...s, { name: 'New section', areas: [] }])}>
        Add a section
      </button>

      <div className="card space-y-4 p-4">
        <h2 className="text-xl">Regular visits</h2>
        <p className="text-sm text-ink-2">Leave the days blank for a one-off clean. Pick days to have Duly book the visits for you after you accept a quote.</p>
        <div className="flex flex-wrap gap-2">
          {weekDays.map((d) => {
            const on = days.includes(d.code)
            return (
              <button
                key={d.code}
                type="button"
                aria-pressed={on}
                className={`btn !min-h-[44px] !px-3 text-sm ${on ? 'btn-primary' : 'btn-ghost'}`}
                onClick={() => {
                  setDays((x) => (on ? x.filter((y) => y !== d.code) : [...x, d.code]))
                  setDirty(true)
                }}
              >
                {d.text}
              </button>
            )
          })}
        </div>
        <label className="block text-sm">
          <span className="mb-1 block font-medium">Start time</span>
          <input
            type="time"
            className="field w-40"
            value={startTime}
            onChange={(e) => {
              setStartTime(e.target.value)
              setDirty(true)
            }}
          />
        </label>
        <label className="block text-sm">
          <span className="mb-1 block font-medium">Notes for the cleaner</span>
          <textarea
            className="field min-h-[72px] py-2"
            value={notes}
            onChange={(e) => {
              setNotes(e.target.value)
              setDirty(true)
            }}
          />
        </label>
      </div>

      <div className="card sticky bottom-3 space-y-3 p-4 shadow-lg">
        <p className="text-sm text-ink-2">
          {schedule.reduce((n, s) => n + s.areas.length, 0)} areas · {hoursLabel(totalMinutes(schedule))} per visit
        </p>
        <ErrorNote message={error} />
        <div className="flex flex-wrap gap-2">
          <button type="button" className="btn btn-ghost" disabled={busy || !dirty} onClick={() => void save()}>
            {dirty ? 'Save draft' : 'Saved'}
          </button>
          {confirmLock ? (
            <>
              <button type="button" className="btn btn-primary" disabled={busy} onClick={() => void lock()}>
                Yes, lock it
              </button>
              <button type="button" className="btn btn-ghost" onClick={() => setConfirmLock(false)}>
                Not yet
              </button>
            </>
          ) : (
            <button type="button" className="btn btn-primary" disabled={busy} onClick={() => setConfirmLock(true)}>
              Lock brief and find vendors
            </button>
          )}
        </div>
      </div>
    </div>
  )
}

function AddStandard({ onAdd }: { onAdd: (text: string) => void }) {
  const [text, setText] = useState('')
  return (
    <div className="flex gap-2">
      <input
        className="field text-sm"
        placeholder="Add a standard, e.g. “Skirting boards dust-free”"
        value={text}
        onChange={(e) => setText(e.target.value)}
      />
      <button
        type="button"
        className="btn btn-ghost shrink-0 text-sm"
        disabled={!text.trim()}
        onClick={() => {
          onAdd(text.trim())
          setText('')
        }}
      >
        Add
      </button>
    </div>
  )
}

function AddArea({ areaTypes, onAdd }: { areaTypes: string[]; onAdd: (name: string, minutes: number, areaType: string) => void }) {
  const [name, setName] = useState('')
  const [minutes, setMinutes] = useState(15)
  const [areaType, setAreaType] = useState('')
  return (
    <div className="flex flex-wrap items-center gap-2 bg-ground/60 p-4">
      <input className="field min-w-[10rem] flex-1" placeholder="New area" value={name} onChange={(e) => setName(e.target.value)} />
      <input type="number" min={1} className="field w-20" value={minutes} aria-label="Minutes" onChange={(e) => setMinutes(Number(e.target.value))} />
      <select className="field w-auto" value={areaType} aria-label="Type of area" onChange={(e) => setAreaType(e.target.value)}>
        <option value="">Type (adds standards)</option>
        {areaTypes.map((t) => (
          <option key={t} value={t}>
            {t.replace(/_/g, ' ')}
          </option>
        ))}
      </select>
      <button
        type="button"
        className="btn btn-ghost text-sm"
        disabled={!name.trim() || minutes <= 0}
        onClick={() => {
          onAdd(name.trim(), minutes, areaType)
          setName('')
        }}
      >
        Add area
      </button>
    </div>
  )
}

type Ranked = { org_id: string; name: string; km: number; quality_score: number | null; verification_tier: number; hourly_rate: number; rank: number }
type QuoteRow = {
  id: string
  status: string
  total: number | null
  currency: string
  lines: Json
  valid_until: string | null
  brief_version: number
  vendor: { id: string; name: string } | null
}

const tierLabel = ['Unverified', 'ID checked', 'Insured and checked', 'Fully verified']

function Vendors({
  briefId,
  version,
  siteId,
  quotes,
  currency,
  onChange,
}: {
  briefId: string
  version: number
  siteId: string
  quotes: QuoteRow[]
  currency: string
  onChange: () => void
}) {
  const [ranked, setRanked] = useState<Ranked[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState<string | null>(null)

  useEffect(() => {
    supabase()
      .rpc('rank_vendors', { p_site: siteId })
      .then(({ data, error: err }) => {
        if (err) setError(err.message)
        setRanked((data ?? []) as Ranked[])
      })
  }, [siteId])

  async function invite(vendorId: string) {
    setBusy(vendorId)
    const { error: err } = await supabase().from('quotes').insert({ brief_id: briefId, brief_version: version, vendor_org_id: vendorId })
    setBusy(null)
    if (err) return setError(err.message)
    onChange()
  }

  const asked = new Map(quotes.filter((q) => q.brief_version === version).map((q) => [q.vendor?.id, q.status]))

  return (
    <Section title="Vendors who cover this site">
      <p className="text-sm text-ink-2">
        Ranked by Duly on quality, verification and distance. Price doesn't affect the order. Ask as many as you like for a quote.
      </p>
      <ErrorNote message={error} />
      {!ranked ? (
        <Loading />
      ) : ranked.length === 0 ? (
        <Empty title="No verified vendors cover this site yet">We'll show vendors here as they join and pass verification.</Empty>
      ) : (
        <ol className="space-y-2">
          {ranked.map((v) => (
            <li key={v.org_id} className="card flex flex-wrap items-center justify-between gap-3 p-4">
              <div className="flex items-start gap-3">
                <span className="mt-0.5 flex size-7 shrink-0 items-center justify-center rounded-full bg-tint text-sm font-semibold text-primary">
                  {v.rank}
                </span>
                <div>
                  <p className="font-semibold">{v.name}</p>
                  <p className="text-sm text-ink-2">
                    {v.quality_score != null ? `Quality ${v.quality_score}` : 'New on Duly'} · {tierLabel[v.verification_tier]} · {v.km} km ·{' '}
                    {money(v.hourly_rate, currency)}/h
                  </p>
                </div>
              </div>
              {asked.has(v.org_id) ? (
                <Badge value={asked.get(v.org_id) ?? 'invited'} />
              ) : (
                <button className="btn btn-primary text-sm" disabled={busy === v.org_id} onClick={() => void invite(v.org_id)}>
                  Ask for a quote
                </button>
              )}
            </li>
          ))}
        </ol>
      )}
    </Section>
  )
}

function Quotes({ quotes, currency, hasPattern }: { quotes: QuoteRow[]; currency: string; hasPattern: boolean }) {
  const navigate = useNavigate()
  const submitted = quotes.filter((q) => q.status === 'submitted' || q.status === 'accepted')
  const tomorrow = new Date(Date.now() + 86400000)
  tomorrow.setHours(9, 0, 0, 0)
  const pad = (n: number) => String(n).padStart(2, '0')
  const defaultStart = `${tomorrow.getFullYear()}-${pad(tomorrow.getMonth() + 1)}-${pad(tomorrow.getDate())}T09:00`
  const [start, setStart] = useState(defaultStart)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function accept(quoteId: string) {
    setBusy(true)
    setError(null)
    const { data, error: err } = await supabase().rpc('accept_quote', { p_quote: quoteId, p_start: new Date(start).toISOString() })
    setBusy(false)
    if (err) return setError(err.message)
    // Regular visits: book the next four weeks straight away (no-op for one-off briefs).
    const job = await supabase().from('jobs').select('contract_id').eq('id', data).single()
    if (job.data?.contract_id && hasPattern) await supabase().rpc('schedule_visits', { p_contract: job.data.contract_id, p_weeks: 4 })
    await navigate({ to: '/jobs/$jobId', params: { jobId: data } })
  }

  return (
    <Section title="Quotes">
      {submitted.length === 0 ? (
        <Empty title="No quotes back yet">Quotes appear here as vendors respond. Each one is priced from your brief, area by area.</Empty>
      ) : (
        <div className="space-y-3">
          {submitted.map((q) => {
            const price = (q.lines ?? {}) as Price
            return (
              <div key={q.id} className="card p-4">
                <div className="flex items-start justify-between gap-3">
                  <div>
                    <p className="font-semibold">{q.vendor?.name}</p>
                    <p className="text-sm text-ink-2">Valid until {day(q.valid_until)}</p>
                  </div>
                  <p className="font-display text-2xl">{money(q.total, q.currency || currency)}</p>
                </div>
                <details className="mt-2 text-sm">
                  <summary className="cursor-pointer py-2 font-medium text-primary">See how it's priced</summary>
                  <ul className="space-y-1 text-ink-2">
                    {(price.lines ?? []).map((l) => (
                      <li key={l.area_id} className="flex justify-between">
                        <span>
                          {l.name} · {l.minutes} min
                        </span>
                        <span>{money(l.amount, q.currency)}</span>
                      </li>
                    ))}
                    {price.urgency_amount ? (
                      <li className="flex justify-between">
                        <span>Urgency</span>
                        <span>{money(price.urgency_amount, q.currency)}</span>
                      </li>
                    ) : null}
                  </ul>
                </details>
                {q.status === 'accepted' ? (
                  <Badge value="accepted" />
                ) : (
                  <div className="mt-3 flex flex-wrap items-end gap-2">
                    <label className="text-sm">
                      <span className="mb-1 block font-medium">First clean</span>
                      <input type="datetime-local" className="field" value={start} onChange={(e) => setStart(e.target.value)} />
                    </label>
                    <button className="btn btn-primary" disabled={busy} onClick={() => void accept(q.id)}>
                      Accept and book
                    </button>
                  </div>
                )}
              </div>
            )
          })}
          <ErrorNote message={error} />
        </div>
      )}
    </Section>
  )
}

function NewVersion({ briefId, version, schedule, onDone }: { briefId: string; version: number; schedule: Json; onDone: () => void }) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  async function start() {
    setBusy(true)
    const db = supabase()
    const res = await db.from('brief_versions').insert({ brief_id: briefId, version: version + 1, schedule })
    if (!res.error) await db.from('briefs').update({ current_version: version + 1, status: 'draft' }).eq('id', briefId)
    setBusy(false)
    if (res.error) return setError(res.error.message)
    onDone()
  }
  return (
    <div className="border-t border-line pt-6">
      <p className="text-sm text-ink-2">
        Need to change something? Locked versions never change. You can start version {version + 1}, and new quotes will be priced
        on that.
      </p>
      <button className="btn btn-ghost mt-3" disabled={busy} onClick={() => void start()}>
        Start version {version + 1}
      </button>
      <ErrorNote message={error} />
    </div>
  )
}

const weekDays = [
  { code: 'mon', text: 'Mon' },
  { code: 'tue', text: 'Tue' },
  { code: 'wed', text: 'Wed' },
  { code: 'thu', text: 'Thu' },
  { code: 'fri', text: 'Fri' },
  { code: 'sat', text: 'Sat' },
  { code: 'sun', text: 'Sun' },
]

function VisitsSummary({ days, start, notes }: { days: string[] | null; start: string | null; notes: string | null }) {
  if (!days?.length && !notes) return null
  return (
    <div className="card space-y-1 p-4 text-sm">
      {days?.length ? (
        <p>
          <span className="font-semibold">Regular visits:</span>{' '}
          {weekDays.filter((d) => days.includes(d.code)).map((d) => d.text).join(', ')} at {start?.slice(0, 5)}
        </p>
      ) : null}
      {notes && (
        <p>
          <span className="font-semibold">Notes:</span> {notes}
        </p>
      )}
    </div>
  )
}

type ContractRow = { id: string; status: string; brief_version: number; billing: string; vendor: { name: string } | null }

function Contracts({ contracts, hasPattern }: { contracts: ContractRow[]; hasPattern: boolean }) {
  const [msg, setMsg] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const active = contracts.filter((c) => c.status === 'active')
  if (active.length === 0) return null

  async function schedule(id: string) {
    setError(null)
    setMsg(null)
    const { data, error: err } = await supabase().rpc('schedule_visits', { p_contract: id, p_weeks: 4 })
    if (err) return setError(err.message)
    setMsg(data === 0 ? 'The next four weeks are already booked.' : `Booked ${data} more visit(s).`)
  }

  return (
    <Section title="Booked with">
      {active.map((c) => (
        <div key={c.id} className="card flex flex-wrap items-center justify-between gap-3 p-4">
          <div>
            <p className="font-semibold">{c.vendor?.name}</p>
            <p className="text-sm text-ink-2">
              Version {c.brief_version} · {c.billing === 'monthly' ? 'Monthly plan' : 'Paid per clean'}
            </p>
          </div>
          {hasPattern && (
            <button className="btn btn-ghost text-sm" onClick={() => void schedule(c.id)}>
              Book the next 4 weeks
            </button>
          )}
        </div>
      ))}
      {msg && <p className="rounded-lg bg-tint p-3 text-sm text-primary">{msg}</p>}
      <ErrorNote message={error} />
    </Section>
  )
}
