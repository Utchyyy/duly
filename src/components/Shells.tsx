import { Link } from '@tanstack/react-router'
import type { ReactNode } from 'react'
import { useAuth } from '#/lib/auth'

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
    <Link to="/account" className={`inline-flex min-h-[44px] items-center text-sm font-medium ${light ? 'text-pro-ink' : 'text-ink-2'}`}>
      Account
    </Link>
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

export type NavItem = { label: string; to: string; exact?: boolean }

/** Duly Pro and Duly Admin: desktop console, 1440px design width, dark sidebar. */
export function ConsoleShell({ suffix, nav, children }: { suffix: string; nav: NavItem[]; children: ReactNode }) {
  return (
    <div className="min-h-screen md:grid md:grid-cols-[240px_1fr]">
      <aside className="bg-pro p-5 text-pro-ink md:min-h-screen">
        <div className="flex items-center justify-between">
          <Link to="/" className="inline-flex min-h-[44px] items-center">
            <Wordmark suffix={suffix} light />
          </Link>
          <div className="md:hidden">
            <AccountButton light />
          </div>
        </div>
        <nav className="mt-6 flex gap-1 overflow-x-auto md:mt-8 md:flex-col">
          {nav.map((item) => (
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
