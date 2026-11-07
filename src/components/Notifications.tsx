import { Link } from '@tanstack/react-router'
import { useCallback, useEffect, useState } from 'react'
import { useAuth } from '#/lib/auth'
import { supabase } from '#/lib/supabase'

/** How many notifications the signed-in person has not read. Refreshes every minute and when the tab regains focus. */
export function useUnreadCount(): number {
  const { session } = useAuth()
  const userId = session?.user.id
  const [count, setCount] = useState(0)

  const load = useCallback(async () => {
    if (!userId) return setCount(0)
    const { count: n, error } = await supabase().from('notifications').select('id', { count: 'exact', head: true }).is('read_at', null)
    if (!error) setCount(n ?? 0)
  }, [userId])

  useEffect(() => {
    void load()
    const timer = window.setInterval(() => void load(), 60_000)
    const onFocus = () => void load()
    window.addEventListener('focus', onFocus)
    window.addEventListener('duly:notifications-changed', onFocus)
    return () => {
      window.clearInterval(timer)
      window.removeEventListener('focus', onFocus)
      window.removeEventListener('duly:notifications-changed', onFocus)
    }
  }, [load])

  return count
}

/** Tell the bell to recount (after marking things read). */
export function notifyChanged() {
  window.dispatchEvent(new Event('duly:notifications-changed'))
}

export function NotificationBell({ light }: { light?: boolean }) {
  const unread = useUnreadCount()
  return (
    <Link
      to="/notifications"
      aria-label={unread ? `Notifications, ${unread} unread` : 'Notifications'}
      className={`relative inline-flex min-h-[44px] min-w-[44px] items-center justify-center ${light ? 'text-pro-ink' : 'text-ink-2'}`}
    >
      <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        <path d="M6 9a6 6 0 1 1 12 0c0 5 2 6.5 2 6.5H4S6 14 6 9Z" />
        <path d="M10 19a2 2 0 0 0 4 0" />
      </svg>
      {unread > 0 && (
        <span className="absolute right-1 top-1.5 min-w-[18px] rounded-full bg-primary px-1 text-center text-[11px] font-semibold leading-[18px] text-white">
          {unread > 9 ? '9+' : unread}
        </span>
      )}
    </Link>
  )
}
