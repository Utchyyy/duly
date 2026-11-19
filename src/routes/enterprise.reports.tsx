import { createFileRoute } from '@tanstack/react-router'
import { useState } from 'react'
import type { FormEvent } from 'react'
import { Empty } from '#/components/Shells'
import { Badge, ErrorNote, Field, Loading, Section } from '#/components/ui'
import { label, must, useLoad, when } from '#/lib/format'
import { pct } from '#/lib/measures'
import { exceptionsCsv, monthLabel, packCsv, packFileName, shiftMonth, thisMonth } from '#/lib/sla'
import type { ExceptionRow, PackRow } from '#/lib/sla'
import { supabase } from '#/lib/supabase'
import { useEnterprise } from '#/lib/useEnterprise'

export const Route = createFileRoute('/enterprise/reports')({ component: EnterpriseReports })

function download(name: string, text: string) {
  const url = URL.createObjectURL(new Blob([text], { type: 'text/csv;charset=utf-8' }))
  const a = document.createElement('a')
  a.href = url
  a.download = name
  a.click()
  URL.revokeObjectURL(url)
}

const clock = (iso: string) => new Date(iso).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })

function EnterpriseReports() {
  const enterprise = useEnterprise()!
  const [month, setMonth] = useState(thisMonth())
  const now = thisMonth()
  const { data, error, reload } = useLoad(async () => {
    const db = supabase()
    const [pack, exceptions, targets] = await Promise.all([
      db.rpc('enterprise_sla_pack', { p_enterprise: enterprise.id, p_month: month }),
      db.rpc('enterprise_sla_exceptions', { p_enterprise: enterprise.id, p_month: month }),
      db.from('enterprise_sla_targets').select('on_time_rate, evidenced_rate, max_complaints_per_100').eq('enterprise_org_id', enterprise.id).maybeSingle(),
    ])
    return { pack: must(pack) as PackRow[], exceptions: must(exceptions) as ExceptionRow[], targets: targets.error ? null : targets.data }
  }, [enterprise.id, month])

  if (error && !data) return <ErrorNote message={error} />
  if (!data) return <Loading />

  const vendors = data.pack.filter((r) => r.is_vendor_total)
  const sitesOf = (name: string) => data.pack.filter((r) => !r.is_vendor_total && r.vendor_name === name)
  const partial = month === now

  return (
    <div className="space-y-8">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p className="text-sm font-medium text-primary">{enterprise.name}</p>
          <h1 className="mt-1 text-3xl">Monthly SLA pack</h1>
          <p className="mt-1 max-w-2xl text-sm text-ink-2 print:hidden">
            How each vendor delivered at your sites in the month, per vendor and per site, with the visits behind the numbers. Download it as a spreadsheet or print it.
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-2 print:hidden">
          <button className="btn btn-ghost text-sm" onClick={() => setMonth(shiftMonth(month, -1))} aria-label="Previous month">
            ← Previous
          </button>
          <span className="min-w-[8.5rem] text-center font-semibold">{monthLabel(month)}</span>
          <button className="btn btn-ghost text-sm" disabled={month >= now} onClick={() => setMonth(shiftMonth(month, 1))} aria-label="Next month">
            Next →
          </button>
        </div>
      </div>
      <p className="hidden print:block">
        {enterprise.name} · {monthLabel(month)}
      </p>
      {partial && <p className="rounded-lg bg-tint p-3 text-sm print:border print:border-line">This month is not over, so the pack is partial: it counts the visits that have come due so far.</p>}

      <div className="flex flex-wrap gap-2 print:hidden">
        <button className="btn btn-primary" disabled={data.pack.length === 0} onClick={() => download(packFileName('pack', enterprise.name, month), packCsv(month, enterprise.name, data.pack))}>
          Download the pack (CSV)
        </button>
        <button className="btn btn-ghost" disabled={data.exceptions.length === 0} onClick={() => download(packFileName('visits', enterprise.name, month), exceptionsCsv(month, enterprise.name, data.exceptions))}>
          Download the visits behind it (CSV)
        </button>
        <button className="btn btn-ghost" onClick={() => window.print()}>
          Print or save as PDF
        </button>
      </div>

      <Levels enterpriseId={enterprise.id} canManage={enterprise.canManage} targets={data.targets} onSaved={reload} />

      {vendors.length === 0 ? (
        <Empty title="No visits in this month">When a vendor delivers at your sites, the month's pack appears here.</Empty>
      ) : (
        <div className="space-y-6">
          {vendors.map((v) => (
            <Section key={v.vendor_org_id} title={v.vendor_name}>
              <Figures row={v} strong />
              {sitesOf(v.vendor_name).length > 0 && (
                <div className="grid gap-3 md:grid-cols-2">
                  {sitesOf(v.vendor_name).map((s) => (
                    <div key={s.site_name ?? ''} className="card space-y-2 p-4">
                      <p className="font-semibold">{s.site_name}</p>
                      <Figures row={s} />
                    </div>
                  ))}
                </div>
              )}
            </Section>
          ))}
        </div>
      )}

      {data.exceptions.length > 0 && (
        <Section title="The visits behind the numbers">
          <p className="text-sm text-ink-2">Every visit this month that was missed, late, or complained about.</p>
          <ul className="space-y-2">
            {data.exceptions.map((x) => (
              <li key={`${x.vendor_name}-${x.site_name}-${x.scheduled_start}`} className="card space-y-1 p-4 text-sm print:break-inside-avoid">
                <p className="font-semibold">
                  {when(x.scheduled_start)} – {x.vendor_name} · {x.site_name}
                </p>
                <p className="flex flex-wrap items-center gap-2">
                  {x.missed && <Badge value="expired">Missed</Badge>}
                  {x.late_minutes != null && <Badge value="awaiting">{x.late_minutes} min after the start</Badge>}
                  {x.complaints > 0 && (
                    <Badge value={x.open_complaints > 0 ? 'rejected' : 'resolved'}>
                      {x.complaints} complaint{x.complaints === 1 ? '' : 's'}: {(x.complaint_kinds ?? '').split(', ').map(label).join(', ')}
                      {x.open_complaints > 0 ? `, ${x.open_complaints} open` : ''}
                    </Badge>
                  )}
                  {x.sla_breached && <Badge value="expired">Past response time</Badge>}
                </p>
              </li>
            ))}
          </ul>
        </Section>
      )}
      <p className="hidden text-xs text-ink-2 print:block">Produced by Duly from the visit record on {new Date().toLocaleDateString('en-GB')} {clock(new Date().toISOString())}.</p>
    </div>
  )
}

function Result({ met, text }: { met: boolean | null; text: string }) {
  if (met == null) return null
  return <Badge value={met ? 'accepted' : 'rejected'}>{met ? `Met ${text}` : `Not met ${text}`}</Badge>
}

function Figures({ row, strong }: { row: PackRow; strong?: boolean }) {
  return (
    <div className={strong ? 'card space-y-3 p-4' : 'space-y-2'}>
      <dl className="grid grid-cols-2 gap-x-4 gap-y-2 text-sm sm:grid-cols-4">
        <Fig term="Visits scheduled" value={String(row.scheduled_visits)} note={`${row.due_visits} due`} />
        <Fig term="Evidenced" value={pct(row.evidenced_rate)} note={`${row.evidenced_visits} of ${row.due_visits} due`} />
        <Fig term="On time" value={pct(row.on_time_rate)} note={`${row.on_time_visits} of ${row.checked_in_visits} arrived`} />
        <Fig term="Right first time" value={pct(row.first_time_right_rate)} />
        <Fig term="Late" value={String(row.late_visits)} watch={row.late_visits > 0} />
        <Fig term="Missed" value={String(row.missed_visits)} watch={row.missed_visits > 0} />
        <Fig term="Complaints" value={String(row.complaints)} note={row.complaints_per_100 == null ? undefined : `${row.complaints_per_100} per 100 visits`} watch={row.open_complaints > 0} />
        <Fig term="Past response time" value={String(row.sla_breaches)} watch={row.sla_breaches > 0} />
      </dl>
      <p className="flex flex-wrap gap-2">
        <Result met={row.on_time_met} text={`on time (${pct(row.on_time_target)} wanted)`} />
        <Result met={row.evidenced_met} text={`evidenced (${pct(row.evidenced_target)} wanted)`} />
        <Result met={row.complaints_met} text={`complaints (${row.max_complaints_per_100} per 100 at most)`} />
      </p>
    </div>
  )
}

function Fig({ term, value, note, watch }: { term: string; value: string; note?: string; watch?: boolean }) {
  return (
    <div>
      <dt className="text-ink-2">{term}</dt>
      <dd className={`font-semibold ${watch ? 'text-alert' : ''}`}>{value}</dd>
      {note && <dd className="text-xs text-ink-2">{note}</dd>}
    </div>
  )
}

type Targets = { on_time_rate: number | null; evidenced_rate: number | null; max_complaints_per_100: number | null } | null

function Levels({ enterpriseId, canManage, targets, onSaved }: { enterpriseId: string; canManage: boolean; targets: Targets; onSaved: () => void }) {
  const [editing, setEditing] = useState(false)
  const [onTime, setOnTime] = useState('')
  const [evidenced, setEvidenced] = useState('')
  const [complaints, setComplaints] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const none = !targets || (targets.on_time_rate == null && targets.evidenced_rate == null && targets.max_complaints_per_100 == null)

  function start() {
    setOnTime(targets?.on_time_rate == null ? '' : String(Math.round(targets.on_time_rate * 1000) / 10))
    setEvidenced(targets?.evidenced_rate == null ? '' : String(Math.round(targets.evidenced_rate * 1000) / 10))
    setComplaints(targets?.max_complaints_per_100 == null ? '' : String(targets.max_complaints_per_100))
    setError(null)
    setEditing(true)
  }

  async function save(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError(null)
    const share = (v: string) => (v.trim() === '' ? null : Number(v) / 100)
    const { error: err } = await supabase().rpc('enterprise_set_sla_targets', {
      p_enterprise: enterpriseId,
      p_on_time: share(onTime),
      p_evidenced: share(evidenced),
      p_max_complaints: complaints.trim() === '' ? null : Number(complaints),
    })
    setBusy(false)
    if (err) return setError(err.message)
    setEditing(false)
    onSaved()
  }

  return (
    <Section title="Service levels">
      {!editing ? (
        <div className="flex flex-wrap items-center gap-3">
          {none ? (
            <p className="text-sm text-ink-2">No service levels set, so the pack shows the rates without judging them.</p>
          ) : (
            <ul className="flex flex-wrap gap-2 text-sm">
              {targets?.on_time_rate != null && <li className="rounded-full bg-tint px-3 py-1 font-medium text-primary">On time: {pct(targets.on_time_rate)} or more</li>}
              {targets?.evidenced_rate != null && <li className="rounded-full bg-tint px-3 py-1 font-medium text-primary">Evidenced: {pct(targets.evidenced_rate)} or more</li>}
              {targets?.max_complaints_per_100 != null && <li className="rounded-full bg-tint px-3 py-1 font-medium text-primary">Complaints: {targets.max_complaints_per_100} per 100 visits at most</li>}
            </ul>
          )}
          {canManage && (
            <button className="btn btn-ghost text-sm print:hidden" onClick={start}>
              {none ? 'Set service levels' : 'Change'}
            </button>
          )}
        </div>
      ) : (
        <form onSubmit={save} className="card max-w-xl space-y-4 p-4">
          <p className="text-sm text-ink-2">Leave a measure empty if you do not set a level for it.</p>
          <Field label="On time: lowest share of arrivals (%)" htmlFor="sla-ontime" hint="For example 95">
            <input id="sla-ontime" className="field" inputMode="decimal" value={onTime} onChange={(e) => setOnTime(e.target.value)} />
          </Field>
          <Field label="Evidenced: lowest share of due visits (%)" htmlFor="sla-evidenced" hint="Checked in, every planned area ticked, a photo">
            <input id="sla-evidenced" className="field" inputMode="decimal" value={evidenced} onChange={(e) => setEvidenced(e.target.value)} />
          </Field>
          <Field label="Complaints: most per 100 visits" htmlFor="sla-complaints" hint="For example 5">
            <input id="sla-complaints" className="field" inputMode="decimal" value={complaints} onChange={(e) => setComplaints(e.target.value)} />
          </Field>
          <ErrorNote message={error} />
          <div className="flex gap-2">
            <button className="btn btn-primary" disabled={busy}>
              Save
            </button>
            <button type="button" className="btn btn-ghost" onClick={() => setEditing(false)}>
              Cancel
            </button>
          </div>
        </form>
      )}
    </Section>
  )
}
