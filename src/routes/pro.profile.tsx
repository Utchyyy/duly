import { createFileRoute } from '@tanstack/react-router'
import { useEffect, useState } from 'react'
import type { FormEvent } from 'react'
import { ErrorNote, Field, Loading } from '#/components/ui'
import { lookupPostcode, must, useLoad } from '#/lib/format'
import { supabase } from '#/lib/supabase'
import { useVendor } from '#/lib/vendor'

export const Route = createFileRoute('/pro/profile')({ component: ProProfile })

function ProProfile() {
  const vendor = useVendor()!
  const { data, error } = useLoad(async () => {
    const db = supabase()
    const [profile, org] = await Promise.all([
      db.from('vendor_profiles').select('*').eq('org_id', vendor.id).maybeSingle(),
      db.from('organisations').select('market, markets(currency)').eq('id', vendor.id).single(),
    ])
    return { profile: profile.data, currency: must(org).markets?.currency ?? 'GBP' }
  }, [vendor.id])

  const [description, setDescription] = useState('')
  const [postcode, setPostcode] = useState('')
  const [radius, setRadius] = useState(15)
  const [rate, setRate] = useState('')
  const [sameDay, setSameDay] = useState(15)
  const [within2h, setWithin2h] = useState(50)
  const [busy, setBusy] = useState(false)
  const [saved, setSaved] = useState(false)
  const [formError, setFormError] = useState<string | null>(null)

  useEffect(() => {
    if (!data?.profile) return
    const p = data.profile
    setDescription(p.description ?? '')
    setRadius(Number(p.service_radius_km))
    setRate(p.hourly_rate != null ? String(p.hourly_rate) : '')
    const u = (p.urgency_pct ?? {}) as Record<string, number>
    setSameDay(Number(u.same_day ?? 15))
    setWithin2h(Number(u.within_2h ?? 50))
  }, [data])

  if (error) return <ErrorNote message={error} />
  if (!data) return <Loading />
  const hasBase = data.profile?.base_lat != null

  async function save(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setSaved(false)
    setFormError(null)
    try {
      let base: { base_lat: number; base_lng: number } | Record<string, never> = {}
      if (postcode.trim()) {
        const geo = await lookupPostcode(postcode)
        if (!geo) throw new Error('We could not find that postcode.')
        base = { base_lat: geo.lat, base_lng: geo.lng }
      } else if (!hasBase) {
        throw new Error('Add your base postcode so clients nearby can find you.')
      }
      const { error: err } = await supabase()
        .from('vendor_profiles')
        .upsert({
          org_id: vendor.id,
          description: description.trim() || null,
          service_radius_km: radius,
          hourly_rate: rate ? Number(rate) : null,
          urgency_pct: { next_slot: 0, same_day: sameDay, within_2h: within2h },
          updated_at: new Date().toISOString(),
          ...base,
        })
      if (err) throw new Error(err.message)
      setSaved(true)
      setPostcode('')
    } catch (err) {
      setFormError(err instanceof Error ? err.message : String(err))
    }
    setBusy(false)
  }

  return (
    <form onSubmit={save} className="max-w-xl space-y-6">
      <h1 className="text-3xl">Profile and rates</h1>
      {!vendor.isAdmin && <p className="text-sm text-alert">Only your company's admin can change these.</p>}
      <div className="card space-y-4 p-5">
        <Field label="What you do" htmlFor="desc" hint="Shown to clients in search.">
          <textarea id="desc" className="field min-h-[88px] py-2" value={description} onChange={(e) => setDescription(e.target.value)} />
        </Field>
        <Field
          label={hasBase ? 'Base postcode (leave blank to keep the current one)' : 'Base postcode'}
          htmlFor="pc"
          hint="Where your cleaners start from. Clients within your radius see you."
        >
          <input id="pc" className="field uppercase" value={postcode} onChange={(e) => setPostcode(e.target.value)} />
        </Field>
        <Field label="Service radius (km)" htmlFor="radius">
          <input id="radius" type="number" min={1} max={200} className="field" value={radius} onChange={(e) => setRadius(Number(e.target.value))} />
        </Field>
      </div>
      <div className="card space-y-4 p-5">
        <Field label={`Hourly rate (${data.currency})`} htmlFor="rate" hint="Every quote is the brief's minutes × this rate. Clients see the breakdown.">
          <input id="rate" type="number" min={1} step="0.5" className="field" value={rate} onChange={(e) => setRate(e.target.value)} />
        </Field>
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Same-day uplift (%)" htmlFor="sd">
            <input id="sd" type="number" min={0} max={200} className="field" value={sameDay} onChange={(e) => setSameDay(Number(e.target.value))} />
          </Field>
          <Field label="Within 2 hours uplift (%)" htmlFor="w2">
            <input id="w2" type="number" min={0} max={300} className="field" value={within2h} onChange={(e) => setWithin2h(Number(e.target.value))} />
          </Field>
        </div>
      </div>
      <ErrorNote message={formError} />
      {saved && <p className="rounded-lg bg-tint p-3 text-sm text-primary">Saved.</p>}
      <button className="btn btn-primary" disabled={busy || !vendor.isAdmin}>
        {busy ? 'Saving…' : 'Save'}
      </button>
    </form>
  )
}
