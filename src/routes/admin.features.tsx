import { createFileRoute } from '@tanstack/react-router'
import { useState } from 'react'
import { ErrorNote, Loading, Section } from '#/components/ui'
import { FEATURE_TEXT } from '#/lib/features'
import type { FeatureKey } from '#/lib/features'
import { supabase } from '#/lib/supabase'
import { useFeatures } from '#/lib/useFeatures'

export const Route = createFileRoute('/admin/features')({ component: AdminFeatures })

function AdminFeatures() {
  const { ready, features, reload } = useFeatures()
  const [busy, setBusy] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  async function set(key: FeatureKey, enabled: boolean) {
    setBusy(key)
    setError(null)
    const { error: err } = await supabase().rpc('admin_set_feature', { p_key: key, p_enabled: enabled })
    setBusy(null)
    if (err) return setError(err.message)
    reload()
  }

  if (!ready) return <Loading />
  return (
    <div className="space-y-8">
      <div>
        <h1 className="text-3xl">Feature switches</h1>
        <p className="mt-1 max-w-2xl text-sm text-ink-2">
          What is open to people right now. Switching something off hides it; nothing is deleted, so switching it back on brings it back. Buyer sign-up is enforced in the database; the others hide screens.
        </p>
      </div>
      <ErrorNote message={error} />
      <Section title="Switches">
        <ul className="space-y-2">
          {(Object.keys(FEATURE_TEXT) as FeatureKey[]).map((k) => (
            <li key={k} className="card flex flex-wrap items-center justify-between gap-3 p-4">
              <div>
                <p className="font-semibold">{FEATURE_TEXT[k].name}</p>
                <p className="text-sm text-ink-2">{FEATURE_TEXT[k].hint}</p>
              </div>
              <label className="flex min-h-[44px] cursor-pointer items-center gap-3 text-sm font-medium">
                <input type="checkbox" className="size-5 accent-[var(--color-primary)]" checked={features[k]} disabled={busy === k} onChange={(e) => void set(k, e.target.checked)} />
                {features[k] ? 'On' : 'Off'}
              </label>
            </li>
          ))}
        </ul>
      </Section>
    </div>
  )
}
