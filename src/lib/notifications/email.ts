/**
 * Turning a notification into an email. Pure functions: no network, no secrets.
 *
 * The notification text is already free of pay, amounts, addresses and access notes (the database sees to that);
 * this only has to be safe to put in an email: escaped, one-line subject, and links that stay inside the app.
 */

export type ClaimedNotification = {
  id: string
  email: string
  title: string
  body: string
  link: string | null
  category: string
  created_at: string
}

export type OutgoingEmail = { to: string; subject: string; text: string; html: string }

export function escapeHtml(value: string): string {
  return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;')
}

/** A single line, safe for a subject header (no line breaks, so nothing can be injected). */
export function oneLine(value: string, max = 120): string {
  return value.replace(/[\r\n\u2028\u2029]+/g, ' ').replace(/\s+/g, ' ').trim().slice(0, max)
}

/** App paths only. Anything else (another site, a scheme, a protocol-relative URL) gets no link. */
export function absoluteLink(appUrl: string, link: string | null | undefined): string | null {
  if (!link || !link.startsWith('/') || link.startsWith('//') || /[\s\\]/.test(link)) return null
  return `${appUrl.replace(/\/+$/, '')}${link}`
}

export function renderEmail(n: ClaimedNotification, appUrl: string): OutgoingEmail {
  const base = appUrl.replace(/\/+$/, '')
  const url = absoluteLink(base, n.link)
  const settings = `${base}/account`
  const subject = oneLine(n.title)

  const text = [n.body, url ? `Open in Duly: ${url}` : '', '--', `You get this email because of your Duly notification settings. Change them here: ${settings}`]
    .filter(Boolean)
    .join('\n\n')

  const html = `<!doctype html>
<html lang="en-GB"><body style="margin:0;padding:24px;background:#F6F3EC;font-family:Helvetica,Arial,sans-serif;color:#1B1F1A">
<div style="max-width:520px;margin:0 auto;background:#FFFFFF;border:1px solid #E2DDD2;border-radius:12px;padding:24px">
<p style="margin:0 0 16px;font-family:Georgia,serif;font-size:20px;font-weight:600">Duly</p>
<h1 style="margin:0 0 12px;font-family:Georgia,serif;font-size:22px;line-height:1.3">${escapeHtml(subject)}</h1>
<p style="margin:0 0 20px;font-size:16px;line-height:1.5;color:#4A5048">${escapeHtml(n.body)}</p>
${url ? `<p style="margin:0 0 24px"><a href="${escapeHtml(url)}" style="display:inline-block;background:#1F5C45;color:#FFFFFF;text-decoration:none;font-weight:600;padding:12px 20px;border-radius:999px">Open in Duly</a></p>` : ''}
<p style="margin:0;font-size:13px;line-height:1.5;color:#4A5048">You get this email because of your Duly notification settings. <a href="${escapeHtml(settings)}" style="color:#1F5C45">Change them</a>.</p>
</div></body></html>`

  return { to: n.email, subject, text, html }
}
