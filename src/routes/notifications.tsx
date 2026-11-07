import { createFileRoute, useRouter } from '@tanstack/react-router'
import { useState } from 'react'
import { Gate } from '#/components/Gate'
import { notifyChanged } from '#/components/Notifications'
import { AppShell, Empty } from '#/components/Shells'
import { ErrorNote, Loading } from '#/components/ui'
import { label, must, ok, useLoad, when } from '#/lib/format'
import { supabase } from '#/lib/supabase'

export const Route = createFileRoute('/notifications')({
  head: () => ({ meta: [{ title: 'Notifications · Duly' }] }),
  component: NotificationsPage,
})

function NotificationsPage() {
  return (
    <AppShell>
      <Gate allowSignUp signInHeading="Sign in">
        <Inbox />
      </Gate>
    </AppShell>
  )
}

/** Links come from the database, which only writes in-app paths. Check anyway before navigating. */
function safePath(link: string | null): string | null {
  return link && link.startsWith('/') && !link.startsWith('//') ? link : null
}

function Inbox() {
  const router = useRouter()
  const { data, error, reload } = useLoad(async () => {
    return must(
      await supabase()
        .from('notifications')
        .select('id, title, body, link, category, created_at, read_at')
        .order('created_at', { ascending: false })
        .limit(100),
    )
  }, [])
  const [busy, setBusy] = useState(false)
  const [problem, setProblem] = useState<string | null>(null)

  async function markAll() {
    setBusy(true)
    setProblem(null)
    try {
      ok(await supabase().rpc('mark_notifications_read', {}))
      notifyChanged()
      reload()
    } catch (e) {
      setProblem(e instanceof Error ? e.message : 'Something went wrong. Please try again.')
    }
    setBusy(false)
  }

  async function open(id: string, link: string | null, wasUnread: boolean) {
    if (wasUnread) {
      await supabase().rpc('mark_notifications_read', { p_ids: [id] })
      notifyChanged()
    }
    const path = safePath(link)
    if (path) router.history.push(path)
    else reload()
  }

  const unread = data?.filter((n) => !n.read_at).length ?? 0

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <h1 className="text-3xl">Notifications</h1>
        {unread > 0 && (
          <button className="btn btn-ghost" disabled={busy} onClick={() => void markAll()}>
            Mark all as read
          </button>
        )}
      </div>
      <ErrorNote message={error ?? problem} />
      {!data ? (
        <Loading />
      ) : data.length === 0 ? (
        <Empty title="Nothing yet">When something needs your attention, such as a quote, a clean to check or a payment due, it appears here.</Empty>
      ) : (
        <ul className="space-y-2">
          {data.map((n) => {
            const isUnread = !n.read_at
            return (
              <li key={n.id}>
                <button
                  className="card flex w-full min-h-[44px] items-start gap-3 p-4 text-left"
                  onClick={() => void open(n.id, n.link, isUnread)}
                >
                  <span aria-hidden="true" className={`mt-2 size-2.5 shrink-0 rounded-full ${isUnread ? 'bg-primary' : 'bg-transparent'}`} />
                  <span className="min-w-0 flex-1">
                    <span className={`block ${isUnread ? 'font-semibold' : 'font-medium text-ink-2'}`}>
                      {n.title}
                      {isUnread && <span className="sr-only"> (unread)</span>}
                    </span>
                    {n.body && <span className="mt-0.5 block text-sm text-ink-2">{n.body}</span>}
                    <span className="mt-1 block text-xs text-ink-2">
                      {label(n.category)} · {when(n.created_at)}
                    </span>
                  </span>
                </button>
              </li>
            )
          })}
        </ul>
      )}
    </div>
  )
}
