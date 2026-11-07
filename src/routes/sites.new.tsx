import { createFileRoute, useNavigate } from '@tanstack/react-router'
import { useState } from 'react'
import type { FormEvent } from 'react'
import { Gate } from '#/components/Gate'
import { AppShell } from '#/components/Shells'
import { ErrorNote, Field, Loading } from '#/components/ui'
import { useAuth } from '#/lib/auth'
import type { Json } from '#/lib/database.types'
import { lookupPostcode, must, ok, useLoad } from '#/lib/format'
import { fromTemplate, hoursLabel, parseSchedule, totalMinutes } from '#/lib/schedule'
import { supabase } from '#/lib/supabase'

export const Route = createFileRoute('/sites/new')({
  validateSearch: (s: Record<string, unknown>) => ({ org: typeof s.org === 'string' ? s.org : '' }),
  head: () => ({ meta: [{ title: 'New brief · Duly' }] }),
  component: NewSitePage,
})

function NewSitePage() {
  return (
    <AppShell wide>
      <Gate allowSignUp signInHeading="Sign in">
        <NewSite />
      </Gate>
    </AppShell>
  )
}

type Template = { id: string; name: string; segment: string | null; sections: Json }

function NewSite() {
  const { org: orgParam } = Route.useSearch()
  const { memberships } = useAuth()
  const navigate = useNavigate()
  const buyer = memberships.find((m) => m.org?.kind === 'buyer' && (!orgParam || m.org.id === orgParam))?.org ?? null

  const { data, error: loadError } = useLoad(async () => {
    if (!buyer) return null
    const db = supabase()
    const [org, sites, templates, library] = await Promise.all([
      db.from('organisations').select('market, segment, markets(postcode_pattern)').eq('id', buyer.id).single(),
      db.from('sites').select('id, name, postcode').eq('org_id', buyer.id).order('name'),
      db.from('schedule_templates').select('id, name, segment, sections').is('vendor_org_id', null).order('name'),
      db.from('standards_library').select('id, segment, area_type, text'),
    ])
    return { org: must(org), sites: must(sites), templates: must(templates) as Template[], library: must(library) }
  }, [buyer?.id])

  const [siteId, setSiteId] = useState<string>('new')
  const [name, setName] = useState('')
  const [address, setAddress] = useState('')
  const [postcode, setPostcode] = useState('')
  const [access, setAccess] = useState('')
  const [templateId, setTemplateId] = useState('')
  const [title, setTitle] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  if (!buyer) return <ErrorNote message="Set up your home or business first." />
  if (loadError) return <ErrorNote message={loadError} />
  if (!data) return <Loading />

  const segment = data.org.segment ?? 'homeowner'
  const templates = [...data.templates].sort((a, b) => Number(b.segment === segment) - Number(a.segment === segment))
  const chosen = templates.find((t) => t.id === templateId)
  const pattern = data.org.markets?.postcode_pattern ? new RegExp(data.org.markets.postcode_pattern, 'i') : null

  async function submit(e: FormEvent) {
    e.preventDefault()
    if (!buyer || !data) return
    setBusy(true)
    setError(null)
    try {
      const db = supabase()
      let site = siteId
      if (site === 'new') {
        if (pattern && !pattern.test(postcode.trim().toUpperCase())) throw new Error('That postcode does not look right.')
        const geo = await lookupPostcode(postcode)
        if (!geo) throw new Error('We could not find that postcode. Check it and try again.')
        const inserted = must(
          await db
            .from('sites')
            .insert({
              org_id: buyer.id,
              name: name.trim(),
              address_line1: address.trim() || null,
              postcode: geo.postcode,
              town: geo.town,
              lat: geo.lat,
              lng: geo.lng,
              access_notes: access.trim() || null,
            })
            .select('id')
            .single(),
        )
        site = inserted.id
      }
      const schedule = chosen ? fromTemplate(chosen.sections, data.library, segment) : []
      const brief = must(
        await db
          .from('briefs')
          .insert({ buyer_org_id: buyer.id, site_id: site, title: title.trim() || chosen?.name || 'Cleaning brief' })
          .select('id')
          .single(),
      )
      ok(await db.from('brief_versions').insert({ brief_id: brief.id, version: 1, schedule: schedule as unknown as Json }))
      await navigate({ to: '/briefs/$briefId', params: { briefId: brief.id } })
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
      setBusy(false)
    }
  }

  return (
    <form onSubmit={submit} className="mx-auto max-w-xl space-y-8">
      <h1 className="text-3xl">New brief</h1>

      <section className="card space-y-4 p-5">
        <h2 className="text-xl">Where</h2>
        {data.sites.length > 0 && (
          <Field label="Site" htmlFor="site">
            <select id="site" className="field" value={siteId} onChange={(e) => setSiteId(e.target.value)}>
              {data.sites.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.name} ({s.postcode})
                </option>
              ))}
              <option value="new">Add a new site…</option>
            </select>
          </Field>
        )}
        {siteId === 'new' && (
          <>
            <Field label="Name" htmlFor="name" hint={segment === 'homeowner' ? 'e.g. "Home"' : 'e.g. "Colchester gym"'}>
              <input id="name" className="field" required value={name} onChange={(e) => setName(e.target.value)} />
            </Field>
            <Field label="Address" htmlFor="address">
              <input id="address" className="field" value={address} onChange={(e) => setAddress(e.target.value)} autoComplete="address-line1" />
            </Field>
            <Field label="Postcode" htmlFor="postcode" hint="Used to find vendors who cover you and to check cleaners arrive on site.">
              <input id="postcode" className="field uppercase" required value={postcode} onChange={(e) => setPostcode(e.target.value)} autoComplete="postal-code" />
            </Field>
            <Field label="Access notes" htmlFor="access" hint="Key safe, parking, alarm: shared only with the vendor you book.">
              <textarea id="access" className="field min-h-[88px] py-2" value={access} onChange={(e) => setAccess(e.target.value)} />
            </Field>
          </>
        )}
      </section>

      <section className="card space-y-4 p-5">
        <h2 className="text-xl">What</h2>
        <Field label="Start from" htmlFor="template" hint="You can change every area, time and standard on the next screen.">
          <select id="template" className="field" value={templateId} onChange={(e) => setTemplateId(e.target.value)}>
            <option value="">A blank brief</option>
            {templates.map((t) => (
              <option key={t.id} value={t.id}>
                {t.name}
              </option>
            ))}
          </select>
        </Field>
        {chosen && (
          <p className="text-sm text-ink-2">
            {parseSchedule(chosen.sections).reduce((n, s) => n + s.areas.length, 0)} areas · about{' '}
            {hoursLabel(totalMinutes(parseSchedule(chosen.sections)))} per visit
          </p>
        )}
        <Field label="Brief title" htmlFor="title">
          <input id="title" className="field" value={title} placeholder={chosen?.name ?? 'Cleaning brief'} onChange={(e) => setTitle(e.target.value)} />
        </Field>
      </section>

      <ErrorNote message={error} />
      <button className="btn btn-primary w-full" disabled={busy}>
        {busy ? 'Creating…' : 'Create brief'}
      </button>
    </form>
  )
}
