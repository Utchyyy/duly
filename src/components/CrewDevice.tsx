import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react'
import type { ReactNode } from 'react'
import { useAuth } from '#/lib/auth'
import { flushOutbox, submitPhoto } from '#/lib/crew/outbox'
import type { FlushResult, NewPhoto, OutboxEntry } from '#/lib/crew/outbox'
import { idbOutbox } from '#/lib/crew/outbox-idb'
import { registerCrewServiceWorker } from '#/lib/crew/service-worker'
import { supabaseSink } from '#/lib/crew/supabase-sink'
import { supabase } from '#/lib/supabase'

type OutboxApi = {
  online: boolean
  entries: OutboxEntry[]
  /** Send a photo now, or keep it on the phone if there is no signal. */
  submit: (photo: NewPhoto) => Promise<'sent' | 'queued'>
  flush: (includeFailed?: boolean) => Promise<FlushResult | null>
  discard: (id: string) => Promise<void>
}

const OutboxContext = createContext<OutboxApi | null>(null)

export function useCrewOutbox(): OutboxApi {
  const api = useContext(OutboxContext)
  if (!api) throw new Error('useCrewOutbox needs CrewDevice')
  return api
}

/** One flush at a time across every open tab (Web Locks), on top of the database refusing a duplicate. */
function exclusive<T>(work: () => Promise<T>): Promise<T | null> {
  const locks = (navigator as Navigator & { locks?: LockManager }).locks
  if (!locks) return work()
  return locks.request('duly-crew-outbox', { ifAvailable: true }, async (lock) => (lock ? work() : null)) as Promise<T | null>
}

/** Register the offline worker as soon as anyone opens Crew, signed in or not, so even the first visit is saved. */
export function useCrewServiceWorker() {
  useEffect(() => {
    void registerCrewServiceWorker()
  }, [])
}

/**
 * Crew-wide device behaviour: tracks the connection, keeps the photo outbox, and
 * sends waiting photos whenever the signal returns, the app is opened or comes back to the front, or every half minute.
 */
export function CrewDevice({ children }: { children: ReactNode }) {
  const { session } = useAuth()
  const userId = session?.user.id ?? null
  const [online, setOnline] = useState(true)
  const [entries, setEntries] = useState<OutboxEntry[]>([])
  const running = useRef<Promise<FlushResult | null> | null>(null)

  const refresh = useCallback(async () => {
    if (!userId) return setEntries([])
    try {
      setEntries(await idbOutbox.list(userId))
    } catch {
      setEntries([])
    }
  }, [userId])

  const deps = useCallback(() => ({ store: idbOutbox, sink: supabaseSink(supabase()), online: () => navigator.onLine }), [])

  const flush = useCallback(
    async (includeFailed = false) => {
      if (!userId) return null
      if (running.current) return running.current
      const job = (async () => {
        try {
          return await exclusive(() => flushOutbox({ ...deps(), userId, includeFailed }))
        } catch {
          return null
        } finally {
          running.current = null
          await refresh()
        }
      })()
      running.current = job
      return job
    },
    [userId, deps, refresh],
  )

  useEffect(() => {
    setOnline(navigator.onLine)
    const up = () => {
      setOnline(true)
      void flush()
    }
    const down = () => setOnline(false)
    const wake = () => {
      if (document.visibilityState === 'visible') void flush()
    }
    window.addEventListener('online', up)
    window.addEventListener('offline', down)
    window.addEventListener('focus', wake)
    document.addEventListener('visibilitychange', wake)
    const timer = window.setInterval(() => void flush(), 30_000)
    void refresh().then(() => flush())
    return () => {
      window.removeEventListener('online', up)
      window.removeEventListener('offline', down)
      window.removeEventListener('focus', wake)
      document.removeEventListener('visibilitychange', wake)
      window.clearInterval(timer)
    }
  }, [flush, refresh])

  const submit = useCallback(
    async (photo: NewPhoto) => {
      const outcome = await submitPhoto(deps(), photo)
      await refresh()
      return outcome
    },
    [deps, refresh],
  )

  const discard = useCallback(
    async (id: string) => {
      await idbOutbox.remove(id)
      await refresh()
    },
    [refresh],
  )

  const api = useMemo<OutboxApi>(() => ({ online, entries, submit, flush, discard }), [online, entries, submit, flush, discard])
  return <OutboxContext.Provider value={api}>{children}</OutboxContext.Provider>
}

/** The offline notice and the queue of photos waiting to be sent. Sits at the top of every Crew page. */
export function CrewStatus() {
  const { online, entries, flush, discard } = useCrewOutbox()
  const [busy, setBusy] = useState(false)
  const waiting = entries.filter((e) => e.status === 'waiting')
  const failed = entries.filter((e) => e.status === 'failed')
  if (online && entries.length === 0) return null

  return (
    <div className="mb-5 space-y-3">
      {!online && (
        <p role="status" className="rounded-xl bg-alert-bg p-3 text-sm text-alert">
          <strong>You're offline.</strong> Photos you take are kept on this phone and upload by themselves when you're back online.
          Checking in, ticking standards and finishing a clean need a signal.
        </p>
      )}
      {waiting.length > 0 && (
        <div role="status" className="card flex flex-wrap items-center justify-between gap-3 p-4">
          <p className="text-sm">
            <strong>
              {waiting.length} photo{waiting.length === 1 ? '' : 's'} waiting to upload.
            </strong>{' '}
            <span className="text-ink-2">Saved on this phone until they are sent.</span>
          </p>
          <button
            className="btn btn-primary text-sm"
            disabled={busy || !online}
            onClick={async () => {
              setBusy(true)
              await flush()
              setBusy(false)
            }}
          >
            {busy ? 'Sending…' : 'Upload now'}
          </button>
        </div>
      )}
      {failed.map((e) => (
        <div key={e.id} className="card space-y-2 p-4">
          <p className="text-sm font-medium text-alert">A photo could not be sent.</p>
          <p className="text-sm text-ink-2">{e.lastError ?? 'The server refused it.'}</p>
          <div className="flex gap-2">
            <button
              className="btn btn-ghost text-sm"
              disabled={!online}
              onClick={async () => {
                await flush(true)
              }}
            >
              Try again
            </button>
            <button className="btn btn-ghost text-sm" onClick={() => void discard(e.id)}>
              Discard
            </button>
          </div>
        </div>
      ))}
    </div>
  )
}

type InstallEvent = Event & { prompt: () => Promise<void>; userChoice: Promise<{ outcome: 'accepted' | 'dismissed' }> }
const DISMISSED = 'duly.crew.install.dismissed'

/** "Add to your home screen": the browser's own install prompt where there is one, and the Share-menu hint on iPhone. */
export function InstallCard() {
  const [event, setEvent] = useState<InstallEvent | null>(null)
  const [hidden, setHidden] = useState(true)
  const [ios, setIos] = useState(false)

  useEffect(() => {
    const standalone = window.matchMedia('(display-mode: standalone)').matches || (navigator as Navigator & { standalone?: boolean }).standalone === true
    let dismissed = false
    try {
      dismissed = localStorage.getItem(DISMISSED) === '1'
    } catch {
      // storage unavailable: just show it
    }
    setIos(/iPad|iPhone|iPod/.test(navigator.userAgent) && !('MSStream' in window))
    setHidden(standalone || dismissed)
    const onPrompt = (e: Event) => {
      e.preventDefault()
      setEvent(e as InstallEvent)
    }
    const onInstalled = () => setHidden(true)
    window.addEventListener('beforeinstallprompt', onPrompt)
    window.addEventListener('appinstalled', onInstalled)
    return () => {
      window.removeEventListener('beforeinstallprompt', onPrompt)
      window.removeEventListener('appinstalled', onInstalled)
    }
  }, [])

  if (hidden || (!event && !ios)) return null

  function dismiss() {
    setHidden(true)
    try {
      localStorage.setItem(DISMISSED, '1')
    } catch {
      // fine
    }
  }

  return (
    <div className="card flex flex-wrap items-center justify-between gap-3 bg-tint/50 p-4">
      <p className="min-w-0 flex-1 text-sm">
        <strong>Put Duly Crew on your home screen</strong>
        <span className="block text-ink-2">
          {event ? 'Opens straight to your jobs, and keeps working when the signal drops.' : 'Tap Share, then Add to Home Screen.'}
        </span>
      </p>
      <div className="flex gap-2">
        {event && (
          <button
            className="btn btn-primary text-sm"
            onClick={async () => {
              await event.prompt()
              await event.userChoice
              setEvent(null)
            }}
          >
            Install
          </button>
        )}
        <button className="btn btn-ghost text-sm" onClick={dismiss}>
          Not now
        </button>
      </div>
    </div>
  )
}
