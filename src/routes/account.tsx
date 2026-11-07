import { createFileRoute } from '@tanstack/react-router'
import { useEffect, useState } from 'react'
import type { FormEvent } from 'react'
import { AreaLinks } from '#/components/BuyerHome'
import { Gate } from '#/components/Gate'
import { AppShell } from '#/components/Shells'
import { ErrorNote, Field } from '#/components/ui'
import { useAuth } from '#/lib/auth'
import { useLoad, must } from '#/lib/format'
import { supabase } from '#/lib/supabase'

export const Route = createFileRoute('/account')({
  head: () => ({ meta: [{ title: 'Your account · Duly' }] }),
  component: AccountPage,
})

function AccountPage() {
  return (
    <AppShell>
      <Gate allowSignUp signInHeading="Sign in">
        <Account />
      </Gate>
    </AppShell>
  )
}

function Account() {
  const { session, refresh, signOut } = useAuth()
  const hasPassword = Boolean(session?.user.user_metadata.has_password)
  const [password, setPassword] = useState('')
  const [confirm, setConfirm] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [done, setDone] = useState(false)

  async function save(e: FormEvent) {
    e.preventDefault()
    setError(null)
    setDone(false)
    if (password.length < 8) return setError('Use at least 8 characters.')
    if (password !== confirm) return setError('The two passwords don’t match.')
    setBusy(true)
    const { error: err } = await supabase().auth.updateUser({ password, data: { has_password: true } })
    setBusy(false)
    if (err) return setError(err.message)
    setPassword('')
    setConfirm('')
    setDone(true)
    await refresh()
  }

  return (
    <div className="space-y-6">
      <AreaLinks />
      <div>
        <h1 className="text-3xl">Your account</h1>
        <p className="mt-1 text-ink-2">{session?.user.email}</p>
      </div>
      <form onSubmit={save} className="card space-y-4 p-5">
        <h2 className="text-xl">{hasPassword ? 'Change your password' : 'Set a password'}</h2>
        <p className="text-sm text-ink-2">
          With a password you can sign in straight away on any device, without waiting for a code. You stay signed in on this
          device until you sign out.
        </p>
        <Field label="New password" htmlFor="new-password" hint="At least 8 characters.">
          <input
            id="new-password"
            type="password"
            autoComplete="new-password"
            required
            className="field"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
        </Field>
        <Field label="Type it again" htmlFor="confirm-password">
          <input
            id="confirm-password"
            type="password"
            autoComplete="new-password"
            required
            className="field"
            value={confirm}
            onChange={(e) => setConfirm(e.target.value)}
          />
        </Field>
        <ErrorNote message={error} />
        {done && <p className="rounded-lg bg-tint p-3 text-sm text-primary">Saved. Next time, choose “Password” when you sign in.</p>}
        <button className="btn btn-primary" disabled={busy}>
          {busy ? 'Saving…' : 'Save password'}
        </button>
      </form>
      <NotificationSettings />
      <button className="btn btn-ghost" onClick={() => void signOut()}>
        Sign out
      </button>
    </div>
  )
}

const MUTABLE: { code: string; text: string }[] = [
  { code: 'quotes', text: 'Quotes' },
  { code: 'jobs', text: 'Cleans and crew' },
  { code: 'payments', text: 'Payments' },
  { code: 'shifts', text: 'Shifts' },
  { code: 'verification', text: 'Verification and DBS' },
  { code: 'reminders', text: 'Reminders' },
]

/** Email choices. Everything always appears in the notifications inbox; this only controls email. */
function NotificationSettings() {
  const { session } = useAuth()
  const userId = session?.user.id ?? ''
  const { data, error } = useLoad(async () => {
    const res = await supabase().from('notification_settings').select('email_enabled, email_muted').eq('user_id', userId).maybeSingle()
    return { settings: must({ data: res.data ?? { email_enabled: true, email_muted: [] as string[] }, error: res.error }) }
  }, [userId])
  const [enabled, setEnabled] = useState(true)
  const [muted, setMuted] = useState<string[]>([])
  const [busy, setBusy] = useState(false)
  const [saved, setSaved] = useState(false)
  const [problem, setProblem] = useState<string | null>(null)

  useEffect(() => {
    if (data) {
      setEnabled(data.settings.email_enabled)
      setMuted(data.settings.email_muted)
    }
  }, [data])

  async function save(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setSaved(false)
    setProblem(null)
    const { error: err } = await supabase()
      .from('notification_settings')
      .upsert({ user_id: userId, email_enabled: enabled, email_muted: muted, updated_at: new Date().toISOString() })
    setBusy(false)
    if (err) return setProblem('We could not save that. Please try again.')
    setSaved(true)
  }

  const toggle = (code: string) => setMuted((cur) => (cur.includes(code) ? cur.filter((c) => c !== code) : [...cur, code]))

  return (
    <form onSubmit={save} className="card space-y-4 p-5">
      <h2 className="text-xl">Notifications</h2>
      <p className="text-sm text-ink-2">
        Everything appears under the bell. These choices are only for email. Problems and disputes are always emailed, because they
        have deadlines.
      </p>
      <ErrorNote message={error ?? problem} />
      <label className="flex min-h-[44px] items-center gap-3">
        <input type="checkbox" className="size-5 accent-[var(--color-primary)]" checked={enabled} onChange={(e) => setEnabled(e.target.checked)} />
        <span className="font-medium">Email me about things that need my attention</span>
      </label>
      <fieldset className="space-y-1" disabled={!enabled}>
        <legend className="mb-1 text-sm font-medium text-ink-2">Email me about</legend>
        {MUTABLE.map((c) => (
          <label key={c.code} className="flex min-h-[44px] items-center gap-3">
            <input type="checkbox" className="size-5 accent-[var(--color-primary)]" checked={!muted.includes(c.code)} onChange={() => toggle(c.code)} />
            <span>{c.text}</span>
          </label>
        ))}
      </fieldset>
      {saved && <p className="rounded-lg bg-tint p-3 text-sm text-primary">Saved.</p>}
      <button className="btn btn-primary" disabled={busy}>
        {busy ? 'Saving…' : 'Save notification settings'}
      </button>
    </form>
  )
}
