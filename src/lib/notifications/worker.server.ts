import { createHash, timingSafeEqual } from 'node:crypto'
import { createClient } from '@supabase/supabase-js'
import type { Database } from '../database.types.ts'
import { supabaseConfig } from '../supabase.ts'
import { drainEmails } from './drain.ts'
import { resendSender } from './resend.server.ts'

/** Constant-time check of `Authorization: Bearer <secret>`. No secret configured means nobody is let in. */
export function isAuthorised(header: string | null | undefined, secret: string | undefined): boolean {
  if (!secret || !header) return false
  const match = /^Bearer (.+)$/.exec(header)
  if (!match) return false
  const digest = (v: string) => createHash('sha256').update(v).digest()
  return timingSafeEqual(digest(match[1] ?? ''), digest(secret))
}

type Env = Record<string, string | undefined>

/**
 * Server only. Called by a scheduler (see .github/workflows/notifications.yml) with the CRON_SECRET. Uses the
 * service role to claim and finish queued emails, which nobody else can do, then sends them through the provider.
 */
export async function handleSend(request: Request, env: Env = process.env): Promise<Response> {
  if (!env.CRON_SECRET) return Response.json({ error: 'not configured' }, { status: 503 })
  if (!isAuthorised(request.headers.get('authorization'), env.CRON_SECRET)) return Response.json({ error: 'unauthorised' }, { status: 401 })

  const serviceKey = env.SUPABASE_SERVICE_ROLE_KEY
  if (!serviceKey) return Response.json({ error: 'not configured' }, { status: 503 })
  // Without a provider the emails simply stay queued (they are dropped after 48 hours), so switching it on later is safe.
  if (!env.RESEND_API_KEY || !env.EMAIL_FROM || !env.APP_URL) return Response.json({ configured: false, claimed: 0 })

  const db = createClient<Database>(supabaseConfig().url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })
  const send = resendSender({ apiKey: env.RESEND_API_KEY, from: env.EMAIL_FROM })
  try {
    const summary = await drainEmails({
      appUrl: env.APP_URL,
      now: () => Date.now(),
      send,
      async claim(limit) {
        const { data, error } = await db.rpc('worker_claim_notification_emails', { p_limit: limit })
        if (error) throw new Error(error.message)
        return data ?? []
      },
      async finish(id, sent, error) {
        const res = await db.rpc('worker_finish_notification_email', { p_id: id, p_sent: sent, p_error: error })
        if (res.error) throw new Error(res.error.message)
      },
    })
    return Response.json({ configured: true, ...summary })
  } catch (error) {
    console.error('Email worker failed', error instanceof Error ? error.message : error)
    return Response.json({ error: 'worker failed' }, { status: 500 })
  }
}
