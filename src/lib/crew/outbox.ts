/**
 * Photos taken without a signal. The photo, where it was taken and when are kept on the phone and sent as soon as
 * there is a connection, so evidence is never lost in a basement or a lift.
 *
 * Only photos are queued. Check-in, ticking standards and finishing a clean carry a time and a place that the
 * database records as "now", so they need a real connection and are never replayed later.
 *
 * Sending is safe to repeat: the file's path is fixed when the photo is taken, an upload that finds the file already
 * there counts as done, and the evidence row is only added if it isn't already. The check isn't atomic, so the
 * database has the final say: a unique index on evidence.storage_path, which the real sink treats as "already
 * recorded". A flaky signal, two tabs or a crash half-way through therefore cannot produce a duplicate.
 */

export type PhotoKind = 'photo_before' | 'photo_after'
export type FailureKind = 'network' | 'auth' | 'rejected'

export type OutboxEntry = {
  id: string
  userId: string
  jobId: string
  areaId: string
  /** The cleaning area (from the work schedule) this photo shows, if the crew tagged one. The database files it under its sub-section. */
  planItemId?: string | null
  kind: PhotoKind
  /** Where it will live in the evidence bucket: <job>/<area>/<time>-<kind>.<ext>. Fixed at capture. */
  path: string
  mime: string
  blob: Blob
  lat: number | null
  lng: number | null
  /** When the photo was actually taken, not when it was uploaded. */
  takenAt: string
  createdAt: string
  attempts: number
  /** 'failed' means the server refused it; it is kept so the person can see why and decide. */
  status: 'waiting' | 'failed'
  lastError: string | null
}

export type NewPhoto = Omit<OutboxEntry, 'attempts' | 'status' | 'lastError' | 'createdAt'> & { createdAt?: string }

export interface OutboxStore {
  list: (userId: string) => Promise<OutboxEntry[]>
  put: (entry: OutboxEntry) => Promise<void>
  remove: (id: string) => Promise<void>
}

export class SendError extends Error {
  readonly kind: FailureKind
  constructor(kind: FailureKind, message: string) {
    super(message)
    this.name = 'SendError'
    this.kind = kind
  }
}

/** Sort a failure into: no connection (try again later), signed out (try after sign-in), or refused (don't retry). */
export function classifyError(error: unknown): FailureKind {
  if (error instanceof SendError) return error.kind
  if (error instanceof TypeError) return 'network'
  const e = (error && typeof error === 'object' ? error : {}) as { message?: unknown; status?: unknown; statusCode?: unknown; code?: unknown; name?: unknown }
  const message = typeof error === 'string' ? error : typeof e.message === 'string' ? e.message : ''
  const status = Number(e.status ?? e.statusCode)
  if (status === 401 || e.code === 'PGRST301' || /jwt|token.*expired|expired.*token|not authenticated|invalid claims/i.test(message)) return 'auth'
  if (e.name === 'AbortError' || /failed to fetch|network|load failed|offline|timed? ?out|aborted|econn|enotfound|fetch failed/i.test(message)) return 'network'
  if (status === 408 || status === 429 || (status >= 500 && status < 600)) return 'network'
  return 'rejected'
}

/** What to show a person when something that needs a signal fails. */
export function friendlyError(error: unknown): string {
  const kind = classifyError(error)
  if (kind === 'network') return 'No signal. Try again when you are back online.'
  if (kind === 'auth') return 'You have been signed out. Sign in again and try again.'
  if (error instanceof Error && error.message) return error.message
  if (error && typeof error === 'object' && 'message' in error && typeof (error as { message: unknown }).message === 'string') return (error as { message: string }).message
  return 'Something went wrong. Please try again.'
}

/** The three calls delivering a photo needs. The real ones talk to Supabase; tests use fakes. */
export type PhotoSink = {
  /** Store the file. Resolves if it is stored or was already there. Throws SendError otherwise. */
  upload: (path: string, blob: Blob, mime: string) => Promise<void>
  evidenceExists: (path: string) => Promise<boolean>
  insertEvidence: (row: {
    job_id: string
    area_id: string
    plan_item_id?: string | null
    kind: PhotoKind
    storage_path: string
    taken_at: string
    lat: number | null
    lng: number | null
  }) => Promise<void>
}

/** Upload the file, then add the evidence row unless it is already there. Safe to call again after any failure. */
export async function deliver(sink: PhotoSink, entry: Pick<OutboxEntry, 'jobId' | 'areaId' | 'planItemId' | 'kind' | 'path' | 'mime' | 'blob' | 'lat' | 'lng' | 'takenAt'>): Promise<void> {
  try {
    await sink.upload(entry.path, entry.blob, entry.mime)
    if (!(await sink.evidenceExists(entry.path))) {
      await sink.insertEvidence({
        job_id: entry.jobId,
        area_id: entry.areaId,
        ...(entry.planItemId ? { plan_item_id: entry.planItemId } : {}),
        kind: entry.kind,
        storage_path: entry.path,
        taken_at: entry.takenAt,
        lat: entry.lat,
        lng: entry.lng,
      })
    }
  } catch (error) {
    throw error instanceof SendError ? error : new SendError(classifyError(error), error instanceof Error ? error.message : 'send failed')
  }
}

export type OutboxDeps = { store: OutboxStore; sink: PhotoSink; online: () => boolean }

/**
 * Take a photo: send it now if there is a connection, otherwise (or if the signal drops) keep it on the phone.
 * Returns 'sent' or 'queued'. A refusal by the server (wrong job, file too big, not allowed) is thrown so the person
 * hears about it at once; it is not queued, because retrying would never help.
 */
export async function submitPhoto(deps: OutboxDeps, photo: NewPhoto): Promise<'sent' | 'queued'> {
  const entry: OutboxEntry = { ...photo, createdAt: photo.createdAt ?? new Date().toISOString(), attempts: 0, status: 'waiting', lastError: null }
  if (deps.online()) {
    try {
      await deliver(deps.sink, entry)
      return 'sent'
    } catch (error) {
      if (classifyError(error) === 'rejected') throw error
    }
  }
  await deps.store.put(entry)
  return 'queued'
}

export type FlushResult = { sent: number; failed: number; waiting: number; stoppedBy: 'offline' | 'auth' | null }

/**
 * Send everything waiting for this person, oldest first. Stops at the first sign of no connection or no sign-in
 * (nothing is lost), and parks anything the server refuses as 'failed' with its reason instead of retrying forever.
 */
export async function flushOutbox(deps: OutboxDeps & { userId: string; includeFailed?: boolean }): Promise<FlushResult> {
  const result: FlushResult = { sent: 0, failed: 0, waiting: 0, stoppedBy: null }
  const entries = (await deps.store.list(deps.userId)).sort((a, b) => a.createdAt.localeCompare(b.createdAt))
  for (const entry of entries) {
    if (entry.userId !== deps.userId) continue // never send one person's photos as another
    if (entry.status === 'failed' && !deps.includeFailed) {
      result.failed += 1
      continue
    }
    if (result.stoppedBy) {
      result.waiting += 1
      continue
    }
    if (!deps.online()) {
      result.stoppedBy = 'offline'
      result.waiting += 1
      continue
    }
    try {
      await deliver(deps.sink, entry)
      await deps.store.remove(entry.id)
      result.sent += 1
    } catch (error) {
      const kind = classifyError(error)
      if (kind === 'rejected') {
        await deps.store.put({ ...entry, attempts: entry.attempts + 1, status: 'failed', lastError: error instanceof Error ? error.message.slice(0, 200) : 'refused' })
        result.failed += 1
      } else {
        result.stoppedBy = kind === 'auth' ? 'auth' : 'offline'
        result.waiting += 1
        await deps.store.put({ ...entry, attempts: entry.attempts + 1, status: 'waiting', lastError: null })
      }
    }
  }
  return result
}
