import type { OutgoingEmail } from './email.ts'
import type { SendResult } from './drain.ts'

type Options = { apiKey: string; from: string; fetchImpl?: typeof fetch }

/**
 * Email through Resend's HTTP API. Swap this file to change provider: the rest only needs a function
 * from (email, idempotency key) to ok/error. Errors are reduced to a short code so no provider response
 * (which can echo addresses) is stored or shown.
 */
export function resendSender({ apiKey, from, fetchImpl = fetch }: Options) {
  return async (email: OutgoingEmail, idempotencyKey: string): Promise<SendResult> => {
    try {
      const res = await fetchImpl('https://api.resend.com/emails', {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${apiKey}`,
          'Content-Type': 'application/json',
          'Idempotency-Key': idempotencyKey,
        },
        body: JSON.stringify({ from, to: [email.to], subject: email.subject, text: email.text, html: email.html }),
      })
      if (res.ok) return { ok: true }
      return { ok: false, error: res.status === 429 ? 'provider rate limit' : `provider ${res.status}` }
    } catch {
      return { ok: false, error: 'network error' }
    }
  }
}
