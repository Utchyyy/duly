import { useState } from 'react'
import type { FormEvent } from 'react'
import { supabase } from '#/lib/supabase'

type Props = {
  /** Buyers and operatives can create an account; vendor staff and admins join by invite only. */
  allowSignUp: boolean
  heading?: string
}

function friendly(message: string): string {
  if (/rate limit/i.test(message)) {
    return 'Too many codes have been sent in the last hour. If you have set a password, use it instead. Otherwise try again later.'
  }
  return message
}

export function SignIn({ allowSignUp, heading = 'Sign in' }: Props) {
  const [mode, setMode] = useState<'code' | 'password'>('password')
  const [email, setEmail] = useState('')
  const [code, setCode] = useState('')
  const [password, setPassword] = useState('')
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
        /rate limit/i.test(err.message) || allowSignUp
          ? friendly(err.message)
          : 'No account found for that email. Ask your administrator for an invite.',
      )
      return
    }
    setStep('code')
  }

  async function verify(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError(null)
    const { error: err } = await supabase().auth.verifyOtp({ email: email.trim(), token: code.trim(), type: 'email' })
    setBusy(false)
    if (err) setError('That code did not work. Check it, or send a new one.')
  }

  async function withPassword(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError(null)
    const { error: err } = await supabase().auth.signInWithPassword({ email: email.trim(), password })
    setBusy(false)
    if (err) {
      setError(
        /invalid login/i.test(err.message)
          ? 'Email or password not recognised. New here, or haven’t set a password yet? Use “Email me a code” instead.'
          : friendly(err.message),
      )
    }
  }

  const emailField = (
    <>
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
    </>
  )

  return (
    <div className="card mx-auto w-full max-w-sm p-6">
      <h2 className="text-2xl">{heading}</h2>
      <div className="mt-4 grid grid-cols-2 gap-1 rounded-full bg-ground p-1 text-sm font-semibold" role="tablist">
        {(['password', 'code'] as const).map((m) => (
          <button
            key={m}
            type="button"
            role="tab"
            aria-selected={mode === m}
            className={`min-h-[44px] rounded-full ${mode === m ? 'bg-card text-ink shadow-sm' : 'text-ink-2'}`}
            onClick={() => {
              setMode(m)
              setError(null)
            }}
          >
            {m === 'password' ? 'Password' : 'Email me a code'}
          </button>
        ))}
      </div>

      {mode === 'password' ? (
        <form onSubmit={withPassword} className="mt-4 space-y-3">
          {emailField}
          <label className="block text-sm font-medium" htmlFor="password">
            Password
          </label>
          <input
            id="password"
            type="password"
            required
            autoComplete="current-password"
            className="field"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
          <button className="btn btn-primary w-full" disabled={busy}>
            {busy ? 'Signing in…' : 'Sign in'}
          </button>
          <p className="text-sm text-ink-2">
            First time, or forgotten your password? Use “Email me a code”, then set a password from your account.
          </p>
        </form>
      ) : step === 'email' ? (
        <form onSubmit={sendCode} className="mt-4 space-y-3">
          {emailField}
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
