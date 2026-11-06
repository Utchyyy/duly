import { useEffect, useState } from 'react'
import type { FormEvent } from 'react'
import { useAuth } from '#/lib/auth'
import { supabase } from '#/lib/supabase'
import { Empty } from './Shells'
import { VendorDirectory } from './VendorDirectory'

type Segment = { code: string; name: string }

/** Home for buyers. `mode` decides which segments an account can be started in. */
export function BuyerHome({ mode }: { mode: 'home' | 'business' }) {
  const { memberships, refresh } = useAuth()
  const buyerOrgs = memberships.filter(
    (m) =>
      m.org?.kind === 'buyer' &&
      (mode === 'home' ? m.org.segment === 'homeowner' : m.org.segment !== 'homeowner'),
  )
  const org = buyerOrgs[0]?.org ?? null

  if (!org) return <StartAccount mode={mode} onDone={refresh} />

  return (
    <div className="space-y-8">
      <section>
        <p className="text-sm font-medium text-primary">{org.name}</p>
        <h1 className="mt-1 text-3xl">{mode === 'home' ? 'Your home' : 'Your sites'}</h1>
      </section>
      <section className="space-y-3">
        <h2 className="text-xl">Briefs</h2>
        <Empty title="No briefs yet">
          Add a {mode === 'home' ? 'home' : 'site'} and describe the clean, then lock the brief to get ranked quotes.
        </Empty>
      </section>
      <section className="space-y-3">
        <h2 className="text-xl">Vendors on Duly</h2>
        <VendorDirectory />
      </section>
    </div>
  )
}

function StartAccount({ mode, onDone }: { mode: 'home' | 'business'; onDone: () => Promise<void> }) {
  const [segments, setSegments] = useState<Segment[]>([])
  const [name, setName] = useState('')
  const [segment, setSegment] = useState(mode === 'home' ? 'homeowner' : 'sme')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (mode === 'home') return
    supabase()
      .from('segments')
      .select('code, name')
      .neq('code', 'homeowner')
      .order('name')
      .then(({ data }) => setSegments(data ?? []))
  }, [mode])

  async function submit(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError(null)
    const { error: err } = await supabase().rpc('create_buyer_org', { p_name: name.trim(), p_segment: segment })
    setBusy(false)
    if (err) {
      setError(err.message)
      return
    }
    await onDone()
  }

  return (
    <form onSubmit={submit} className="card mx-auto max-w-sm space-y-3 p-6">
      <h1 className="text-2xl">{mode === 'home' ? 'Set up your home' : 'Set up your business'}</h1>
      <label className="block text-sm font-medium" htmlFor="org-name">
        {mode === 'home' ? 'Name for your home (e.g. "Smith household")' : 'Business name'}
      </label>
      <input id="org-name" className="field" required value={name} onChange={(e) => setName(e.target.value)} />
      {mode === 'business' && (
        <>
          <label className="block text-sm font-medium" htmlFor="segment">
            Type of business
          </label>
          <select id="segment" className="field" value={segment} onChange={(e) => setSegment(e.target.value)}>
            {segments.map((s) => (
              <option key={s.code} value={s.code}>
                {s.name}
              </option>
            ))}
          </select>
        </>
      )}
      <button className="btn btn-primary w-full" disabled={busy}>
        {busy ? 'Setting up…' : 'Continue'}
      </button>
      {error && <p className="rounded-lg bg-alert-bg p-3 text-sm text-alert">{error}</p>}
    </form>
  )
}
