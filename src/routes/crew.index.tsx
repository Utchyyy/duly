import { Link, createFileRoute } from '@tanstack/react-router'
import { useEffect, useState } from 'react'
import type { FormEvent } from 'react'
import { InstallCard } from '#/components/CrewDevice'
import { MyChecks, ShiftOffers } from '#/components/CrewExtras'
import { Empty } from '#/components/Shells'
import { Badge, ErrorNote } from '#/components/ui'
import { friendlyError } from '#/lib/crew/outbox'
import { useAuth } from '#/lib/auth'
import { supabase } from '#/lib/supabase'

export const Route = createFileRoute('/crew/')({ component: CrewHome })

type Assignment = {
  role: string
  job: { id: string; status: string; scheduled_start: string; scheduled_end: string } | null
}

function CrewHome() {
  const { session, hasWorkerRecord, memberships, refresh } = useAuth()
  const isOperative = memberships.some((m) => m.role === 'operative')
  const [assignments, setAssignments] = useState<Assignment[] | null>(null)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [attempt, setAttempt] = useState(0)

  useEffect(() => {
    if (!session) return
    setLoadError(null)
    supabase()
      .from('job_assignments')
      .select('role, job:jobs(id, status, scheduled_start, scheduled_end)')
      .eq('user_id', session.user.id)
      .order('created_at', { ascending: false })
      .then(
        ({ data, error }) => {
          // A failed load is not "no jobs": with no signal, say so rather than tell someone they have no work.
          if (error) return setLoadError(friendlyError(error))
          setAssignments((data ?? []) as Assignment[])
        },
        (e: unknown) => setLoadError(friendlyError(e)),
      )
  }, [session?.user.id, attempt])

  if (!hasWorkerRecord && !isOperative) return <JoinCrew onDone={refresh} />

  return (
    <div className="space-y-6">
      <h1 className="text-3xl">Your jobs</h1>
      <InstallCard />
      {loadError && assignments === null ? (
        <div className="space-y-3">
          <ErrorNote message={loadError} />
          <button className="btn btn-ghost" onClick={() => setAttempt((n) => n + 1)}>
            Try again
          </button>
        </div>
      ) : assignments === null ? (
        <p className="text-ink-2">Loading…</p>
      ) : assignments.length === 0 ? (
        <Empty title="No jobs assigned yet">When your company assigns you a job it will appear here.</Empty>
      ) : (
        <ul className="space-y-3">
          {assignments.map((a) =>
            a.job ? (
              <li key={a.job.id}>
                <Link to="/crew/$jobId" params={{ jobId: a.job.id }} className="card flex items-center justify-between gap-3 p-4">
                  <div>
                    <p className="font-semibold">
                      {new Date(a.job.scheduled_start).toLocaleString('en-GB', {
                        weekday: 'short',
                        day: 'numeric',
                        month: 'short',
                        hour: '2-digit',
                        minute: '2-digit',
                      })}
                    </p>
                    <p className="text-sm text-ink-2">{a.role === 'lead' ? 'Lead' : 'Crew'}</p>
                  </div>
                  <Badge value={a.job.status} />
                </Link>
              </li>
            ) : null,
          )}
        </ul>
      )}
      {hasWorkerRecord && <ShiftOffers />}
      {hasWorkerRecord && <MyChecks />}
    </div>
  )
}

type Town = { id: number; name: string }

function JoinCrew({ onDone }: { onDone: () => Promise<void> }) {
  const { session } = useAuth()
  const [towns, setTowns] = useState<Town[]>([])
  const [fullName, setFullName] = useState('')
  const [townId, setTownId] = useState<number | ''>('')
  const [early, setEarly] = useState(false)
  const [evening, setEvening] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    supabase()
      .from('towns')
      .select('id, name')
      .order('name')
      .then(({ data }) => setTowns(data ?? []))
  }, [])

  async function submit(e: FormEvent) {
    e.preventDefault()
    if (!session || townId === '') return
    setBusy(true)
    setError(null)
    const { error: err } = await supabase().from('workers').insert({
      user_id: session.user.id,
      full_name: fullName.trim(),
      home_town_id: townId,
      available_early: early,
      available_evening: evening,
    })
    setBusy(false)
    if (err) {
      setError(err.message)
      return
    }
    await onDone()
  }

  return (
    <form onSubmit={submit} className="card space-y-3 p-6">
      <h1 className="text-2xl">Join Duly Crew</h1>
      <p className="text-sm text-ink-2">Tell us where you're based so we can offer shifts near you.</p>
      <label className="block text-sm font-medium" htmlFor="full-name">
        Full name
      </label>
      <input id="full-name" className="field" required value={fullName} onChange={(e) => setFullName(e.target.value)} />
      <label className="block text-sm font-medium" htmlFor="town">
        Home town
      </label>
      <select
        id="town"
        className="field"
        required
        value={townId}
        onChange={(e) => setTownId(e.target.value ? Number(e.target.value) : '')}
      >
        <option value="">Choose…</option>
        {towns.map((t) => (
          <option key={t.id} value={t.id}>
            {t.name}
          </option>
        ))}
      </select>
      <label className="flex min-h-[44px] items-center gap-3">
        <input type="checkbox" className="size-5" checked={early} onChange={(e) => setEarly(e.target.checked)} />
        I can start before 7am
      </label>
      <label className="flex min-h-[44px] items-center gap-3">
        <input type="checkbox" className="size-5" checked={evening} onChange={(e) => setEvening(e.target.checked)} />
        I can work after 7pm
      </label>
      <button className="btn btn-primary w-full" disabled={busy}>
        {busy ? 'Saving…' : 'Join'}
      </button>
      {error && <p className="rounded-lg bg-alert-bg p-3 text-sm text-alert">{error}</p>}
    </form>
  )
}
