import { renderEmail } from './email.ts'
import type { ClaimedNotification, OutgoingEmail } from './email.ts'

export type SendResult = { ok: true } | { ok: false; error: string }

/** Everything the drain touches outside itself, so it can be tested without a database or a provider. */
export type DrainDeps = {
  /** Take up to `limit` emails that are due (the database leases them to this worker). */
  claim: (limit: number) => Promise<ClaimedNotification[]>
  /** Report the outcome. A failure is retried later by the database, up to five times. */
  finish: (id: string, sent: boolean, error?: string) => Promise<void>
  /** Hand the email to the provider. `idempotencyKey` makes a repeat harmless. */
  send: (email: OutgoingEmail, idempotencyKey: string) => Promise<SendResult>
  appUrl: string
  now: () => number
}

export type DrainOptions = { batch?: number; maxBatches?: number; budgetMs?: number }
export type DrainSummary = { claimed: number; sent: number; failed: number; errors: number }

/**
 * Send what is due. Each email is claimed, sent and reported one at a time; a problem with one never stops the
 * rest. If reporting an outcome fails, the lease runs out and the email is claimed again later, which is why the
 * notification id is the idempotency key: the provider drops the duplicate.
 */
export async function drainEmails(deps: DrainDeps, options: DrainOptions = {}): Promise<DrainSummary> {
  const batch = options.batch ?? 20
  const maxBatches = options.maxBatches ?? 5
  const budgetMs = options.budgetMs ?? 45_000
  const started = deps.now()
  const summary: DrainSummary = { claimed: 0, sent: 0, failed: 0, errors: 0 }
  const seen = new Set<string>()

  for (let round = 0; round < maxBatches && deps.now() - started < budgetMs; round += 1) {
    const rows = await deps.claim(batch)
    if (rows.length === 0) break
    for (const row of rows) {
      if (seen.has(row.id)) continue
      seen.add(row.id)
      summary.claimed += 1
      let result: SendResult
      try {
        result = await deps.send(renderEmail(row, deps.appUrl), row.id)
      } catch {
        result = { ok: false, error: 'send failed' }
      }
      try {
        await deps.finish(row.id, result.ok, result.ok ? undefined : result.error)
        if (result.ok) summary.sent += 1
        else summary.failed += 1
      } catch {
        summary.errors += 1
      }
    }
    if (rows.length < batch) break
  }
  return summary
}
