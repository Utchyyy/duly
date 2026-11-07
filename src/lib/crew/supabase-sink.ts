import type { Duly } from '../supabase.ts'
import { SendError, classifyError } from './outbox.ts'
import type { PhotoSink } from './outbox.ts'

function fail(error: unknown): never {
  throw new SendError(classifyError(error), error instanceof Error ? error.message : typeof (error as { message?: unknown })?.message === 'string' ? (error as { message: string }).message : 'send failed')
}

/** Delivers a photo with the person's own session, so storage rules and row-level security apply as normal. */
export function supabaseSink(db: Duly): PhotoSink {
  return {
    async upload(path, blob, mime) {
      try {
        const { error } = await db.storage.from('evidence').upload(path, blob, { contentType: mime || 'image/jpeg' })
        if (!error) return
        // The file is already there from an earlier attempt: that is success, not a failure.
        if (/already exists|duplicate/i.test(error.message) || String((error as { statusCode?: unknown }).statusCode) === '409') return
        fail(error)
      } catch (error) {
        if (error instanceof SendError) throw error
        fail(error)
      }
    },
    async evidenceExists(path) {
      try {
        const { data, error } = await db.from('evidence').select('id').eq('storage_path', path).limit(1)
        if (error) fail(error)
        return (data?.length ?? 0) > 0
      } catch (error) {
        if (error instanceof SendError) throw error
        fail(error)
      }
    },
    async insertEvidence(row) {
      try {
        const { error } = await db.from('evidence').insert(row)
        // The database allows one row per stored photo (a unique index). Finding it already there means an earlier
        // attempt got as far as recording it, which is exactly what we wanted.
        if (error && error.code !== '23505') fail(error)
      } catch (error) {
        if (error instanceof SendError) throw error
        fail(error)
      }
    },
  }
}
