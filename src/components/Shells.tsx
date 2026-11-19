import { Link, useRouterState } from '@tanstack/react-router'
import { useEffect, useState } from 'react'
import type { ReactNode } from 'react'
import { hasRole, useAuth } from '#/lib/auth'
import type { Role } from '#/lib/auth'
import { ADMIN_NAV, ENTERPRISE_NAV, PRO_NAV, activeNav, portalFor, visibleNav } from '#/lib/portal'
import type { NavItem } from '#/lib/portal'
import { useEnterprise } from '#/lib/useEnterprise'
import { useFeatures } from '#/lib/useFeatures'
import { NotificationBell } from './Notifications'

function Wordmark({ suffix, light }: { suffix?: string; light?: boolean }) {
  return (
    <span className={`font-display text-2xl font-semibold ${light ? 'text-white' : 'text-ink'}`}>
      Duly
      {suffix && <span className={`ml-1.5 font-sans text-sm font-semibold ${light ? 'text-pro-ink/70' : 'text-primary'}`}>{suffix}</span>}
    </span>
  )
}

function AccountButton({ light }: { light?: boolean }) {
  const { session } = useAuth()
  if (!session) return null
  return (
    <span className="inline-flex items-center gap-1">
      <NotificationBell light={light} />
      <Link to="/account" className={`inline-flex min-h-[44px] items-center text-sm font-medium ${light ? 'text-pro-ink' : 'text-ink-2'}`}>
        Account
      </Link>
    </span>
  )
}

/** Nudges people who signed in with a code to set a password, so they don't depend on email next time. */
function PasswordNudge() {
  const { session } = useAuth()
  if (!session || session.user.user_metadata.has_password) return null
  return (
    <div className="mb-5 flex flex-wrap items-center justify-between gap-x-2 rounded-xl bg-tint px-4 py-1 text-sm text-primary">
      <span>Set a password so you can sign in without waiting for a code.</span>
      <Link to="/account" className="link-action font-semibold underline">
        Set password
      </Link>
    </div>
  )
}

/** Buyer, Business and Crew: mobile-first, 390px design width, centred on desktop. */
export function AppShell({ suffix, children, wide }: { suffix?: string; children: ReactNode; wide?: boolean }) {
  return (
    <div className="min-h-screen">
      <header className="sticky top-0 z-10 border-b border-line bg-ground/90 backdrop-blur">
        <div className={`mx-auto flex h-16 items-center justify-between px-4 ${wide ? 'max-w-5xl' : 'max-w-xl'}`}>
          <Link to="/" className="min-h-[44px] inline-flex items-center">
            <Wordmark suffix={suffix} />
          </Link>
          <AccountButton />
        </div>
      </header>
      <main className={`mx-auto px-4 py-6 ${wide ? 'max-w-5xl' : 'max-w-xl'}`}>
        <PasswordNudge />
        {children}
      </main>
    </div>
  )
}

/**
 * Duly Enterprise, Pro and Admin: a console with a dark sidebar at 1440px. On a small screen the sidebar becomes a bar with a Menu button that
 * names the page you are on and opens the full list, so a long menu is never hidden off the side of the screen.
 */
export function ConsoleShell({ suffix, nav, roles, children }: { suffix: string; nav: NavItem[]; roles: Role[]; children: ReactNode }) {
  const { memberships } = useAuth()
  const pathname = useRouterState({ select: (s) => s.location.pathname })
  const [open, setOpen] = useState(false)
  // The menu names what the console does, so only people who may use it see it (not signed-out visitors or other roles).
  const showNav = hasRole(memberships, [...roles, 'platform_admin'])
  const items = showNav ? nav : []
  const here = activeNav(items, pathname)
  // Following a link closes the menu.
  useEffect(() => {
    setOpen(false)
  }, [pathname])
  return (
    <div className="min-h-screen md:grid md:grid-cols-[240px_1fr] print:block">
      <aside className="bg-pro p-5 text-pro-ink md:min-h-screen print:hidden">
        <div className="flex items-center justify-between">
          <Link to="/" className="inline-flex min-h-[44px] items-center">
            <Wordmark suffix={suffix} light />
          </Link>
          <div className="md:hidden">
            <AccountButton light />
          </div>
        </div>
        {items.length > 0 && (
          <button
            type="button"
            className="mt-3 flex min-h-[44px] w-full items-center justify-between rounded-lg bg-white/10 px-3 text-sm font-semibold text-white md:hidden"
            aria-expanded={open}
            aria-controls="console-menu"
            onClick={() => setOpen((o) => !o)}
          >
            <span>{here ? here.label : 'Menu'}</span>
            <span aria-hidden="true">{open ? 'Close ▴' : 'Menu ▾'}</span>
          </button>
        )}
        <nav id="console-menu" aria-label={`${suffix} menu`} className={`${open ? 'flex' : 'hidden'} mt-2 flex-col gap-1 md:mt-8 md:flex`}>
          {items.map((item) => (
            <Link
              key={item.to}
              to={item.to}
              activeOptions={{ exact: item.exact ?? false }}
              className="flex min-h-[44px] items-center whitespace-nowrap rounded-lg px-3 text-sm text-pro-ink/70 hover:text-white"
              activeProps={{ className: '!bg-white/10 font-semibold !text-white' }}
            >
              {item.label}
            </Link>
          ))}
        </nav>
        <div className="mt-8 hidden md:block">
          <AccountButton light />
        </div>
      </aside>
      <main className="min-w-0 p-5 md:p-10">
        <PasswordNudge />
        {children}
      </main>
    </div>
  )
}

/**
 * For pages several kinds of person share (a visit, a brief, notifications, account): the console of whoever is looking, with its menu, so
 * following a link from Delivery or Dispatch never drops anyone out of their own portal. Duly staff get Admin, an Enterprise's members get
 * Enterprise, a vendor's staff get Pro, a Client gets the sites view and any other buyer the buyer app. Signed out, it is the plain page.
 */
export function PortalShell({ children, wide }: { children: ReactNode; wide?: boolean }) {
  const { ready, session, memberships } = useAuth()
  const enterprise = useEnterprise()
  const { features } = useFeatures()
  if (!ready || !session) return <AppShell wide={wide}>{children}</AppShell>
  const kind = portalFor(
    memberships.map((m) => m.role),
    enterprise !== null,
  )
  const body = <div className={wide ? 'max-w-5xl' : 'max-w-2xl'}>{children}</div>
  if (kind === 'admin')
    return (
      <ConsoleShell suffix="Admin" nav={visibleNav(ADMIN_NAV, features)} roles={['platform_admin']}>
        {body}
      </ConsoleShell>
    )
  if (kind === 'enterprise')
    return (
      <ConsoleShell suffix="Enterprise" nav={ENTERPRISE_NAV} roles={['owner', 'approver', 'viewer']}>
        {body}
      </ConsoleShell>
    )
  if (kind === 'pro')
    return (
      <ConsoleShell suffix="Pro" nav={visibleNav(PRO_NAV, features)} roles={['vendor_admin', 'dispatcher']}>
        {body}
      </ConsoleShell>
    )
  if (kind === 'client')
    return (
      <AppShell suffix="Sites" wide>
        {children}
      </AppShell>
    )
  return <AppShell wide={wide}>{children}</AppShell>
}

export function Stat({ label, value, note }: { label: string; value: ReactNode; note?: string }) {
  return (
    <div className="card p-4">
      <p className="text-sm text-ink-2">{label}</p>
      <p className="mt-1 font-display text-3xl">{value}</p>
      {note && <p className="mt-1 text-xs text-ink-2">{note}</p>}
    </div>
  )
}

export function Empty({ title, children }: { title: string; children?: ReactNode }) {
  return (
    <div className="card border-dashed p-6 text-center">
      <p className="font-semibold">{title}</p>
      {children && <div className="mt-1 text-sm text-ink-2">{children}</div>}
    </div>
  )
}
