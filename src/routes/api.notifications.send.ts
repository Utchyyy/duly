import { createFileRoute } from '@tanstack/react-router'

/**
 * Sends queued notification emails. Not for browsers: it needs the CRON_SECRET, so only a scheduler can call it.
 * GET works as well as POST because Vercel Cron makes GET requests.
 */
async function handle({ request }: { request: Request }): Promise<Response> {
  const { handleSend } = await import('#/lib/notifications/worker.server')
  return handleSend(request)
}

export const Route = createFileRoute('/api/notifications/send')({
  server: { handlers: { GET: handle, POST: handle } },
})
