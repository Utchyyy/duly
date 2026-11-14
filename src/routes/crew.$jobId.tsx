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
import { DAY_FULL, METHOD_LABEL, parsePlan, workForDay } from '#/lib/workplan'
import type { Day } from '#/lib/workplan'

export const Route = createFileRoute('/crew/$jobId')({ component: JobSheet })

function JobSheet() {
  const { jobId } = Route.useParams()
  const { data, error, reload } = useLoad(async () => {
    const db = supabase()
    const job = must(
      await db
        .from('jobs')
        .select('id, status, scheduled_start, scheduled_end, brief_id, brief_version, quote_id, rework_of_issue, site:sites(name, address_line1, town, postcode, access_notes)')
        .eq('id', jobId)
        .single(),
    )
    const [version, evidence, results, events, workSchedule, planDay, planResults, booked, checkMode] = await Promise.all([
      db.from('brief_versions').select('schedule, notes').eq('brief_id', job.brief_id).eq('version', job.brief_version).single(),
      db.from('evidence').select('id, area_id, kind, storage_path, within_geofence, created_at').eq('job_id', jobId).order('created_at'),
      db.from('area_results').select('area_id, standard_id, done_by_operative, verdict').eq('job_id', jobId),
      db.from('job_events').select('kind, at, within_geofence, data').eq('job_id', jobId).eq('kind', 'check_in').order('at'),
      job.quote_id ? db.from('work_schedules').select('plan, legend').eq('quote_id', job.quote_id).maybeSingle() : Promise.resolve({ data: null, error: null }),
      // The visit's weekday when the work schedule decides the check; null means the brief's standards apply.
      db.rpc('job_plan_day', { p_job: jobId }),
      db.from('plan_results').select('plan_item_id, done').eq('job_id', jobId),
      // A rework visit is for one cleaning area: the booking records which (the crew cannot read the client's report itself).
      job.rework_of_issue
        ? db.from('job_events').select('data').eq('job_id', jobId).eq('kind', 'status_change').order('at').limit(1)
        : Promise.resolve({ data: null, error: null }),
      // 'plan': tick the schedule's areas; 'photos': the schedule plans nothing today, so photos only; 'standards': an older job with no schedule.
      db.rpc('job_check_mode', { p_job: jobId }),
    ])
    const bookedData = (booked.data?.[0]?.data ?? null) as { area?: string; item?: string } | null
    return {
      job,
      schedule: parseSchedule(must(version).schedule),
      notes: must(version).notes,
      evidence: must(evidence) as EvidenceRow[],
      results: must(results),
      checkIn: must(events)[0] ?? null,
      // Not an error if there is none: older jobs have no work schedule.
      plan: workSchedule.error || !workSchedule.data ? null : parsePlan(workSchedule.data.plan),
      planDay: planDay.error ? null : ((planDay.data as string | null) as Day | null),
      planResults: planResults.error ? [] : (planResults.data ?? []),
      mode: checkMode.error ? null : (checkMode.data as 'plan' | 'photos' | 'standards' | null),
      rework: job.rework_of_issue ? { area: bookedData?.area ?? null, item: bookedData?.item ?? null } : null,
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
  // With a work schedule that plans something for this weekday, the planned cleaning areas are the checklist.
  const groups = data.plan && data.planDay ? workForDay(data.plan, data.planDay, data.rework?.item) : null
  const rowDone = (id: string) => data.planResults.some((r) => r.plan_item_id === id && r.done)
  const hasAfter = (areaId: string) => data.evidence.some((e) => e.area_id === areaId && e.kind === 'photo_after')
  // A schedule that plans nothing today has no areas: the crew take at least one after photo of the work.
  const photosMode = data.mode === 'photos'
  const areas = photosMode
    ? [{ section: 'Photos of the work', area: { id: 'visit', name: 'The visit', minutes: 0, standards: [] as { id: string; text: string }[] } }]
    : groups
      ? groups.map((g) => ({ section: g.section, area: { id: g.sub.id, name: g.sub.name, minutes: 0, standards: [] as { id: string; text: string }[] } }))
      : data.schedule.flatMap((s) => s.areas.map((a) => ({ section: s.name, area: a })))
  const doneAreas = groups
    ? groups.filter((g) => g.rows.every((r) => rowDone(r.row.id)) && hasAfter(g.sub.id)).length
    : areas.filter(({ area }) => area.standards.every((st) => ticked(area.id, st.id)) && hasAfter(area.id)).length

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

      {data.rework && (
        <p className="card border-primary p-3 text-sm">
          <span className="font-semibold">Rework visit:</span> a client reported a problem, so you are coming back to put one area right
          {data.rework.area ? `: ${data.rework.area}` : ''}. Tick it, take an after photo and finish. There is nothing else to do on this visit.
        </p>
      )}

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

      {photosMode && (
        <p className="card p-3 text-sm text-ink-2">The work schedule plans nothing for this day, so there is no checklist. Do the work, take at least one after photo, then finish.</p>
      )}

      {(working || !beforeStart) && groups && data.planDay && (
        <>
          {working && (
            <p className="text-sm text-ink-2">
              {data.rework ? 'Tick the area when it is right, and take an after photo.' : `${DAY_FULL[data.planDay]}'s work: tick each cleaning area as you finish it, and take an after photo for every part.`} {doneAreas} of {groups.length} parts done.
            </p>
          )}
          {groups.map((g) => (
            <GroupCard
              key={g.sub.id}
              jobId={jobId}
              section={g.section}
              groupId={g.sub.id}
              name={g.sub.name}
              rows={g.rows}
              editable={working}
              done={rowDone}
              evidence={data.evidence.filter((e) => e.area_id === g.sub.id)}
              urls={urls}
              onChange={reload}
            />
          ))}
        </>
      )}

      {(working || !beforeStart) && !groups && (
        <>
          {working && (
            <p className="text-sm text-ink-2">
              {photosMode ? 'Take at least one after photo of the work.' : `For each area: tick every standard and take an after photo. ${doneAreas} of ${areas.length} areas done.`}
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
              {doneAreas < areas.length ? (photosMode ? 'Take an after photo to finish' : `${areas.length - doneAreas} ${groups ? 'part(s)' : 'area(s)'} to finish`) : 'Finish and send to client'}
            </button>
          </div>
        </div>
      )}
    </div>
  )
}

/** Taking and sending photos for one area or sub-section: sent now if there is a signal, otherwise kept on the phone. */
function usePhotos(jobId: string, areaId: string, onChange: () => void) {
  const { session } = useAuth()
  const outbox = useCrewOutbox()
  const saved = outbox.entries.filter((e) => e.jobId === jobId && e.areaId === areaId)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [note, setNote] = useState<string | null>(null)

  async function upload(file: File | undefined, kind: 'photo_before' | 'photo_after', planItemId?: string) {
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
        areaId,
        planItemId: planItemId ?? null,
        kind,
        path: `${jobId}/${areaId}/${Date.now()}-${kind}.${ext}`,
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

  return { busy, error, setError, note, setNote, saved, upload }
}

function SavedNotice({ saved }: { saved: { status: string }[] }) {
  if (saved.length === 0) return null
  const waiting = saved.filter((e) => e.status === 'waiting').length
  return (
    <p className="rounded-lg bg-line/50 p-2 text-xs text-ink-2">
      {waiting > 0 && `${waiting} photo${waiting === 1 ? '' : 's'} saved on this phone, waiting to upload. `}
      {saved.some((e) => e.status === 'failed') && 'One could not be sent: see the notice at the top.'}
    </p>
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
  const photos = usePhotos(jobId, area.id, onChange)
  const { busy, error, setError, note, setNote, saved, upload } = photos
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
          {section}
          {area.minutes > 0 ? ` · ${area.minutes} min` : ''}
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
      <SavedNotice saved={saved} />
      {note && <p className="text-xs text-primary">{note}</p>}
      <ErrorNote message={error} />
    </div>
  )
}

/** One sub-section of the day's work: its cleaning areas to tick, and the photos for that part of the site. */
function GroupCard({
  jobId,
  section,
  groupId,
  name,
  rows,
  editable,
  done,
  evidence,
  urls,
  onChange,
}: {
  jobId: string
  section: string
  groupId: string
  name: string
  rows: { row: { id: string; name: string; standard?: boolean }; method: keyof typeof METHOD_LABEL }[]
  editable: boolean
  done: (id: string) => boolean
  evidence: EvidenceRow[]
  urls: Record<string, string>
  onChange: () => void
}) {
  const { busy, error, setError, note, saved, upload } = usePhotos(jobId, groupId, onChange)
  const before = useRef<HTMLInputElement>(null)
  const after = useRef<HTMLInputElement>(null)
  const rowShot = useRef<HTMLInputElement>(null)
  const [rowFor, setRowFor] = useState<string | null>(null)

  async function toggle(id: string) {
    setError(null)
    const db = supabase()
    const { error: err } = done(id)
      ? await db.from('plan_results').update({ done: false }).eq('job_id', jobId).eq('plan_item_id', id)
      : await db.from('plan_results').upsert({ job_id: jobId, plan_item_id: id, done: true }, { onConflict: 'job_id,plan_item_id' })
    if (err) return setError(friendlyError(err))
    onChange()
  }

  return (
    <div className="card space-y-3 p-4">
      <div>
        <p className="font-semibold">{name}</p>
        <p className="text-xs text-ink-2">{section}</p>
      </div>
      <ul className="space-y-1">
        {rows.map(({ row, method }) => (
          <li key={row.id} className="flex items-center justify-between gap-2">
            <label className={`flex min-h-[44px] flex-1 items-center gap-3 ${editable ? 'cursor-pointer' : ''}`}>
              <input type="checkbox" className="size-5 shrink-0 accent-[var(--color-primary)]" checked={done(row.id)} disabled={!editable} onChange={() => void toggle(row.id)} />
              <span className="text-sm">{row.name}</span>
              <span className="shrink-0 rounded-full bg-tint px-2 py-0.5 text-xs font-semibold text-primary">{row.standard ? 'Client standard' : METHOD_LABEL[method]}</span>
            </label>
            {editable && (
              <button
                className="btn btn-ghost shrink-0 text-xs"
                disabled={busy}
                aria-label={`Photo of ${row.name}`}
                onClick={() => {
                  setRowFor(row.id)
                  rowShot.current?.click()
                }}
              >
                Photo
              </button>
            )}
          </li>
        ))}
      </ul>
      <PhotoStrip rows={evidence} urls={urls} />
      {editable && (
        <div className="flex flex-wrap gap-2">
          <input ref={before} type="file" accept="image/*" capture="environment" className="hidden" onChange={(e) => void upload(e.target.files?.[0], 'photo_before')} />
          <input ref={after} type="file" accept="image/*" capture="environment" className="hidden" onChange={(e) => void upload(e.target.files?.[0], 'photo_after')} />
          <input
            ref={rowShot}
            type="file"
            accept="image/*"
            capture="environment"
            className="hidden"
            onChange={(e) => {
              const f = e.target.files?.[0]
              const id = rowFor ?? undefined
              e.target.value = ''
              void upload(f, 'photo_after', id)
            }}
          />
          <button className="btn btn-ghost text-sm" disabled={busy} onClick={() => before.current?.click()}>
            Before photo
          </button>
          <button className="btn btn-primary text-sm" disabled={busy} onClick={() => after.current?.click()}>
            {busy ? 'Uploading…' : 'After photo'}
          </button>
        </div>
      )}
      <SavedNotice saved={saved} />
      {note && <p className="text-xs text-primary">{note}</p>}
      <ErrorNote message={error} />
    </div>
  )
}
