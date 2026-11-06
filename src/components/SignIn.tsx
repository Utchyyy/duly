import { useState } from 'react'
import type { FormEvent } from 'react'
import { supabase } from '#/lib/supabase'

type Props = {
  /** Buyers and operatives can create an account; vendor staff and admins join by invite only. */
  allowSignUp: boolean
  heading?: string
}

export function SignIn({ allowSignUp, heading = 'Sign in' }: Props) {
  const [email, setEmail] = useState('')
  const [code, setCode] = useState('')
  const [step, setStep] = useState<'email' | 'code'>('email')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function sendCode(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError(null)
    const { error: err } = await supabase().auth.signInWithOtp({
      email: email.trim(),
      options: { shouldCreateUser: allowSignUp },
    })
    setBusy(false)
    if (err) {
      setError(
        allowSignUp ? err.message : 'No account found for that email. Ask your administrator for an invite.',
      )
      return
    }
    setStep('code')
  }

  async function verify(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError(null)
    const { error: err } = await supabase().auth.verifyOtp({
      email: email.trim(),
      token: code.trim(),
      type: 'email',
    })
    setBusy(false)
    if (err) setError('That code did not work. Check it, or send a new one.')
  }

  return (
    <div className="card mx-auto w-full max-w-sm p-6">
      <h2 className="text-2xl">{heading}</h2>
      {step === 'email' ? (
        <form onSubmit={sendCode} className="mt-4 space-y-3">
          <label className="block text-sm font-medium" htmlFor="email">
            Email
          </label>
          <input
            id="email"
            type="email"
            required
            autoComplete="email"
            className="field"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
          />
          <button className="btn btn-primary w-full" disabled={busy}>
            {busy ? 'Sending…' : 'Email me a code'}
          </button>
          {!allowSignUp && <p className="text-sm text-ink-2">Invite only. Use the email your invite was sent to.</p>}
        </form>
      ) : (
        <form onSubmit={verify} className="mt-4 space-y-3">
          <p className="text-sm text-ink-2">We sent a code to {email}.</p>
          <label className="block text-sm font-medium" htmlFor="code">
            Code
          </label>
          <input
            id="code"
            inputMode="numeric"
            autoComplete="one-time-code"
            required
            className="field tracking-[0.3em]"
            value={code}
            onChange={(e) => setCode(e.target.value)}
          />
          <button className="btn btn-primary w-full" disabled={busy}>
            {busy ? 'Checking…' : 'Sign in'}
          </button>
          <button type="button" className="btn btn-ghost w-full" onClick={() => setStep('email')}>
            Use a different email
          </button>
        </form>
      )}
      {error && <p className="mt-3 rounded-lg bg-alert-bg p-3 text-sm text-alert">{error}</p>}
    </div>
  )
}
