import { Link, createFileRoute } from '@tanstack/react-router'
import { useRef, useState } from 'react'
import { useCrewOutbox } from '#/components/CrewDevice'
import { PhotoStrip, useSignedUrls } from '#/components/Evidence'
import type { EvidenceRow } from '#/components/Evidence'
import { Badge, ErrorNote, Loading } from '#/components/ui'
import { useAuth } from '#/lib/auth'
import { friendlyError } from '#/lib/crew/outbox'
import { must, position, useLoad, when } from '#/lib/format'
import { parseSchedule } from '#/lib/schedule'
import type { Area } from '#/lib/schedule'
import { supabase } from '#/lib/supabase'
import { DAY_FULL, METHOD_LABEL, dayOf, parsePlan, workForDay } from '#/lib/workplan'
import type { Plan } from '#/lib/workplan'

export const Route = createFileRoute('/crew/$jobId')({ component: JobSheet })

function JobSheet() {
  const { jobId } = Route.useParams()
  const { data, error, reload } = useLoad(async () => {
    const db = supabase()
    const job = must(
      await db
        .from('jobs')
        .select('id, status, scheduled_start, scheduled_end, brief_id, brief_version, quote_id, site:sites(name, address_line1, town, postcode, access_notes)')
        .eq('id', jobId)
        .single(),
    )
    const [version, evidence, results, events, workSchedule] = await Promise.all([
      db.from('brief_versions').select('schedule, notes').eq('brief_id', job.brief_id).eq('version', job.brief_version).single(),
      db.from('evidence').select('id, area_id, kind, storage_path, within_geofence, created_at').eq('job_id', jobId).order('created_at'),
      db.from('area_results').select('area_id, standard_id, done_by_operative, verdict').eq('job_id', jobId),
      db.from('job_events').select('kind, at, within_geofence, data').eq('job_id', jobId).eq('kind', 'check_in').order('at'),
      job.quote_id ? db.from('work_schedules').select('plan, legend').eq('quote_id', job.quote_id).maybeSingle() : Promise.resolve({ data: null, error: null }),
    ])
    return {
      job,
      schedule: parseSchedule(must(version).schedule),
      notes: must(version).notes,
      evidence: must(evidence) as EvidenceRow[],
      results: must(results),
      checkIn: must(events)[0] ?? null,
      // Not an error if there is none: older jobs have no work schedule.
      plan: workSchedule.error || !workSchedule.data ? null : parsePlan(workSchedule.data.plan),
    }
  }, [jobId])
  const urls = useSignedUrls(data?.evidence)
  const outbox = useCrewOutbox()
  const waitingPhotos = outbox.entries.filter((e) => e.jobId === jobId).length
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState<string | null>(null)
  const [actionError, setActionError] = useState<string | null>(null)
  const [triedWhileWaiting, setTriedWhileWaiting] = useState(false)

  if (error && !data) {
    return (
      <div className="space-y-3">
        <ErrorNote message={friendlyError(error)} />
        <button className="btn btn-ghost" onClick={reload}>
          Try again
        </button>
      </div>
    )
  }
  if (!data) return <Loading />
  const { job } = data
  const working = job.status === 'in_progress'
  const beforeStart = ['matched', 'en_route', 'on_site', 'requested'].includes(job.status)

  async function checkIn() {
    setBusy(true)
    setActionError(null)
    const pos = await position()
    const { data: res, error: err } = await supabase()
      .rpc('check_in', { p_job: jobId, p_lat: pos.lat as number, p_lng: pos.lng as number })
      .then(
        (r) => r,
        (e: unknown) => ({ data: null, error: { message: friendlyError(e) } }),
      )
    setBusy(false)
    // Checking in records the time and place as "now", so it is never queued: it needs a real connection.
    if (err) return setActionError(friendlyError(err))
    const r = (res ?? {}) as { within_geofence: boolean | null; late_minutes: number }
    setMessage(
      r.within_geofence === false
        ? 'Checked in, but your location looks away from the site. The client will see this.'
        : r.within_geofence === null
          ? 'Checked in. We could not read your location.'
          : 'Checked in on site.',
    )
    reload()
  }

  async function complete() {
    setActionError(null)
    if (waitingPhotos > 0) return setTriedWhileWaiting(true)
    setTriedWhileWaiting(false)
    setBusy(true)
    const pos = await position()
    const { error: err } = await supabase()
      .rpc('complete_job', { p_job: jobId, p_lat: pos.lat as number, p_lng: pos.lng as number })
      .then(
        (r) => r,
        (e: unknown) => ({ data: null, error: { message: friendlyError(e) } }),
      )
    setBusy(false)
    if (err) return setActionError(friendlyError(err))
    setMessage('Done. The client has been asked to check the work.')
    reload()
  }

  const ticked = (area: string, std: string) => data.results.some((r) => r.area_id === area && r.standard_id === std && r.done_by_operative)
  const areas = data.schedule.flatMap((s) => s.areas.map((a) => ({ section: s.name, area: a })))
  const doneAreas = areas.filter(
    ({ area }) => area.standards.every((st) => ticked(area.id, st.id)) && data.evidence.some((e) => e.area_id === area.id && e.kind === 'photo_after'),
  ).length

  return (
    <div className="space-y-6 pb-24">
      <div>
        <Link to="/crew" className="link-action text-sm font-medium text-primary">
          ← Your jobs
        </Link>
        <div className="mt-2 flex items-center gap-3">
          <h1 className="text-2xl">{when(job.scheduled_start)}</h1>
          <Badge value={job.status} />
        </div>
        <p className="mt-1 font-medium">{job.site?.name}</p>
        <p className="text-sm text-ink-2">
          {[job.site?.address_line1, job.site?.town, job.site?.postcode].filter(Boolean).join(', ')}
        </p>
        {job.site?.postcode && (
          <a
            href={`https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(job.site.postcode)}`}
            target="_blank"
            rel="noreferrer"
            className="link-action text-sm font-semibold text-primary"
          >
            Directions
          </a>
        )}
        {job.site?.access_notes && <p className="card mt-3 p-3 text-sm">Access: {job.site.access_notes}</p>}
        {data.notes && <p className="card mt-2 p-3 text-sm">Client notes: {data.notes}</p>}
      </div>

      {message && <p className="rounded-lg bg-tint p-3 text-sm text-primary">{message}</p>}
      <ErrorNote
        message={
          triedWhileWaiting && waitingPhotos > 0
            ? `${waitingPhotos} photo${waitingPhotos === 1 ? ' is' : 's are'} still waiting to upload. Finish once they have gone, which needs a signal.`
            : (actionError ?? (error ? `We couldn't refresh this job just now, so what you see may be out of date. ${friendlyError(error)}` : null))
        }
      />

      {beforeStart && (
        <button className="btn btn-primary w-full" disabled={busy} onClick={() => void checkIn()}>
          {busy ? 'Checking in…' : "I've arrived: check in"}
        </button>
      )}

      {data.plan && <TodaysWork plan={data.plan} start={job.scheduled_start} />}

      {(working || !beforeStart) && (
        <>
          {working && (
            <p className="text-sm text-ink-2">
              For each area: tick every standard and take an after photo. {doneAreas} of {areas.length} areas done.
            </p>
          )}
          {areas.map(({ section, area }) => (
            <AreaCard
              key={area.id}
              jobId={jobId}
              section={section}
              area={area}
              editable={working}
              ticked={(std) => ticked(area.id, std)}
              evidence={data.evidence.filter((e) => e.area_id === area.id)}
              urls={urls}
              onChange={reload}
            />
          ))}
        </>
      )}

      {working && (
        <div className="fixed inset-x-0 bottom-0 border-t border-line bg-ground/95 p-3 backdrop-blur">
          <div className="mx-auto max-w-xl">
            <button className="btn btn-primary w-full" disabled={busy || doneAreas < areas.length} onClick={() => void complete()}>
              {doneAreas < areas.length ? `${areas.length - doneAreas} area(s) to finish` : 'Finish and send to client'}
            </button>
          </div>
        </div>
      )}
    </div>
  )
}

function AreaCard({
  jobId,
  section,
  area,
  editable,
  ticked,
  evidence,
  urls,
  onChange,
}: {
  jobId: string
  section: string
  area: Area
  editable: boolean
  ticked: (std: string) => boolean
  evidence: EvidenceRow[]
  urls: Record<string, string>
  onChange: () => void
}) {
  const { session } = useAuth()
  const outbox = useCrewOutbox()
  const saved = outbox.entries.filter((e) => e.jobId === jobId && e.areaId === area.id)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [note, setNote] = useState<string | null>(null)
  const before = useRef<HTMLInputElement>(null)
  const after = useRef<HTMLInputElement>(null)

  async function toggle(std: string) {
    setError(null)
    const db = supabase()
    const { error: err } = ticked(std)
      ? await db.from('area_results').update({ done_by_operative: false }).eq('job_id', jobId).eq('area_id', area.id).eq('standard_id', std)
      : await db
          .from('area_results')
          .upsert({ job_id: jobId, area_id: area.id, standard_id: std, done_by_operative: true }, { onConflict: 'job_id,area_id,standard_id' })
    if (err) return setError(friendlyError(err))
    onChange()
  }

  async function upload(file: File | undefined, kind: 'photo_before' | 'photo_after') {
    if (!file) return
    const userId = session?.user.id
    if (!userId) return setError('Please sign in again.')
    setBusy(true)
    setError(null)
    setNote(null)
    try {
      // Where and when the photo was taken is fixed now, so a late upload still records the real time and place.
      const pos = await position()
      const ext = file.type === 'image/png' ? 'png' : file.type === 'image/webp' ? 'webp' : file.type === 'image/heic' ? 'heic' : 'jpg'
      const outcome = await outbox.submit({
        id: crypto.randomUUID(),
        userId,
        jobId,
        areaId: area.id,
        kind,
        path: `${jobId}/${area.id}/${Date.now()}-${kind}.${ext}`,
        mime: file.type || 'image/jpeg',
        blob: file,
        lat: pos.lat,
        lng: pos.lng,
        takenAt: new Date().toISOString(),
      })
      if (outcome === 'sent') onChange()
      else setNote('Saved on this phone. It will upload as soon as you have a signal.')
    } catch (err) {
      setError(friendlyError(err))
    }
    setBusy(false)
  }

  async function robotAssist() {
    const { data: user } = await supabase().auth.getUser()
    const { error: err } = await supabase()
      .from('job_events')
      .insert({ job_id: jobId, kind: 'robot_handoff', actor: user.user?.id, data: { area_id: area.id, area: area.name } })
    if (err) return setError(friendlyError(err))
    setNote('Robot assist logged for this area.')
  }

  return (
    <div className="card space-y-3 p-4">
      <div className="flex items-baseline justify-between gap-2">
        <p className="font-semibold">{area.name}</p>
        <p className="text-xs text-ink-2">
          {section} · {area.minutes} min
        </p>
      </div>
      <ul className="space-y-1">
        {area.standards.map((st) => (
          <li key={st.id}>
            <label className={`flex min-h-[44px] items-center gap-3 ${editable ? 'cursor-pointer' : ''}`}>
              <input type="checkbox" className="size-5 accent-[var(--color-primary)]" checked={ticked(st.id)} disabled={!editable} onChange={() => void toggle(st.id)} />
              <span className="text-sm">{st.text}</span>
            </label>
          </li>
        ))}
      </ul>
      <PhotoStrip rows={evidence} urls={urls} />
      {editable && (
        <div className="flex flex-wrap gap-2">
          <input ref={before} type="file" accept="image/*" capture="environment" className="hidden" onChange={(e) => void upload(e.target.files?.[0], 'photo_before')} />
          <input ref={after} type="file" accept="image/*" capture="environment" className="hidden" onChange={(e) => void upload(e.target.files?.[0], 'photo_after')} />
          <button className="btn btn-ghost text-sm" disabled={busy} onClick={() => before.current?.click()}>
            Before photo
          </button>
          <button className="btn btn-primary text-sm" disabled={busy} onClick={() => after.current?.click()}>
            {busy ? 'Uploading…' : 'After photo'}
          </button>
          <button className="btn btn-ghost text-sm" onClick={() => void robotAssist()}>
            Robot assist
          </button>
        </div>
      )}
      {saved.length > 0 && (
        <p className="rounded-lg bg-line/50 p-2 text-xs text-ink-2">
          {saved.filter((e) => e.status === 'waiting').length > 0 &&
            `${saved.filter((e) => e.status === 'waiting').length} photo${saved.filter((e) => e.status === 'waiting').length === 1 ? '' : 's'} saved on this phone, waiting to upload. `}
          {saved.some((e) => e.status === 'failed') && 'One could not be sent: see the notice at the top.'}
        </p>
      )}
      {note && <p className="text-xs text-primary">{note}</p>}
      <ErrorNote message={error} />
    </div>
  )
}

/** What the work schedule says to do on the day of this visit, grouped as the client will see it. */
function TodaysWork({ plan, start }: { plan: Plan; start: string }) {
  const day = dayOf(new Date(start))
  const groups = workForDay(plan, day)
  return (
    <section className="card space-y-3 p-4">
      <h2 className="text-lg">Today's work: {DAY_FULL[day]}</h2>
      {groups.length === 0 ? (
        <p className="text-sm text-ink-2">The schedule has no cleaning areas planned for {DAY_FULL[day]}. Do the areas on the checklist below.</p>
      ) : (
        groups.map((g) => (
          <div key={g.sub.id}>
            <p className="text-xs font-semibold uppercase tracking-wide text-ink-2">
              {g.section} · {g.sub.name}
            </p>
            <ul className="mt-1 space-y-1">
              {g.rows.map(({ row, method }) => (
                <li key={row.id} className="flex items-baseline justify-between gap-3 text-sm">
                  <span>{row.name}</span>
                  <span className="shrink-0 rounded-full bg-tint px-2 py-0.5 text-xs font-semibold text-primary">{METHOD_LABEL[method]}</span>
                </li>
              ))}
            </ul>
          </div>
        ))
      )}
    </section>
  )
}
