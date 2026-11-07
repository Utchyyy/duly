import { createFileRoute } from '@tanstack/react-router'
import { useState } from 'react'
import type { FormEvent } from 'react'
import { AreaLinks } from '#/components/BuyerHome'
import { Gate } from '#/components/Gate'
import { AppShell } from '#/components/Shells'
import { ErrorNote, Field } from '#/components/ui'
import { useAuth } from '#/lib/auth'
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
      <button className="btn btn-ghost" onClick={() => void signOut()}>
        Sign out
      </button>
    </div>
  )
}
