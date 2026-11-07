import { Link, createFileRoute, useNavigate } from '@tanstack/react-router'
import { useMemo, useState } from 'react'
import { Gate } from '#/components/Gate'
import { AppShell } from '#/components/Shells'
import { Badge, ErrorNote, Field, Loading, Section } from '#/components/ui'
import { useAuth } from '#/lib/auth'
import type { Json } from '#/lib/database.types'
import { DAYS, DraftError, draftTotals, sanitiseDraft } from '#/lib/drafting/brief-draft'
import type { BriefDraft, Day } from '#/lib/drafting/brief-draft'
import { lookupPostcode, must, ok, useLoad } from '#/lib/format'
import { hoursLabel } from '#/lib/schedule'
import { supabase } from '#/lib/supabase'

export const Route = createFileRoute('/drafts/$itemId')({
  head: () => ({ meta: [{ title: 'Review draft · Duly' }] }),
  component: DraftPage,
})

function DraftPage() {
  return (
    <AppShell>
      <Gate allowSignUp signInHeading="Sign in">
        <Draft />
      </Gate>
    </AppShell>
  )
}

const DAY_LABEL: Record<Day, string> = { mon: 'Mon', tue: 'Tue', wed: 'Wed', thu: 'Thu', fri: 'Fri', sat: 'Sat', sun: 'Sun' }

function Draft() {
  const { itemId } = Route.useParams()
  const { data, error } = useLoad(async () => {
    const db = supabase()
    const item = must(
      await db
        .from('approval_queue')
        .select('id, org_id, status, draft, source, reject_reason, result_brief_id, created_at')
        .eq('id', itemId)
        .single(),
    )
    const sites = must(await db.from('sites').select('id, name, postcode').eq('org_id', item.org_id).order('name'))
    return { item, sites }
  }, [itemId])

  if (error) return <ErrorNote message="We could not find that draft." />
  if (!data) return <Loading />

  let draft: BriefDraft | null = null
  try {
    draft = sanitiseDraft(data.item.draft)
  } catch (e) {
    if (!(e instanceof DraftError)) throw e
  }
  if (!draft) return <ErrorNote message="This draft could not be read. Start a new one, or begin a brief by hand." />
  return <Review item={data.item} sites={data.sites} initial={draft} />
}

type Item = { id: string; org_id: string; status: string; source: Json; reject_reason: string | null; result_brief_id: string | null }

function sourceLabel(source: Json): string {
  const s = (source && typeof source === 'object' && !Array.isArray(source) ? source : {}) as Record<string, Json>
  if (typeof s.file_path === 'string') return `the document you uploaded (${s.file_path.split('/').pop()?.replace(/^\d+-/, '') ?? 'file'})`
  return 'the description you pasted'
}

function Review({ item, sites, initial }: { item: Item; sites: { id: string; name: string; postcode: string | null }[]; initial: BriefDraft }) {
  const { memberships } = useAuth()
  const navigate = useNavigate()
  const canReview = memberships.some((m) => m.org_id === item.org_id && (m.role === 'owner' || m.role === 'approver'))
  const pending = item.status === 'pending'
  const homeTo = memberships.find((m) => m.org_id === item.org_id)?.org?.segment === 'homeowner' ? '/' : '/business'

  const [title, setTitle] = useState(initial.title)
  const [siteChoice, setSiteChoice] = useState<string>('new')
  const [site, setSite] = useState(initial.site)
  const [days, setDays] = useState<Day[]>(initial.visits.days)
  const [start, setStart] = useState(initial.visits.start_time)
  const [rejecting, setRejecting] = useState(false)
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [problem, setProblem] = useState<string | null>(null)

  const totals = useMemo(() => draftTotals(initial), [initial])

  async function approve() {
    setProblem(null)
    if (!title.trim()) return setProblem('Give the brief a title.')
    setBusy(true)
    try {
      const db = supabase()
      const edited: BriefDraft = { ...initial, title: title.trim(), site, visits: { days, start_time: start } }
      let lat: number | undefined
      let lng: number | undefined
      let postcode = site.postcode
      let town = site.town
      if (siteChoice === 'new') {
        if (!site.name.trim()) throw new Error('Give the site a name.')
        const geo = await lookupPostcode(site.postcode)
        if (!geo) throw new Error('We could not find that postcode. Check it and try again.')
        lat = geo.lat
        lng = geo.lng
        postcode = geo.postcode
        town = site.town || geo.town
        edited.site = { ...site, postcode, town }
      }
      const res = await db.rpc('approve_brief_draft', {
        p_item: item.id,
        p_draft: edited as unknown as Json,
        ...(siteChoice === 'new' ? { p_site_lat: lat, p_site_lng: lng } : { p_site: siteChoice }),
      })
      const briefId = must(res)
      await navigate({ to: '/briefs/$briefId', params: { briefId } })
    } catch (err) {
      setProblem(err instanceof Error ? err.message : 'Something went wrong. Please try again.')
      setBusy(false)
    }
  }

  async function reject() {
    setBusy(true)
    setProblem(null)
    try {
      ok(await supabase().rpc('reject_brief_draft', { p_item: item.id, p_reason: reason.trim() || undefined }))
      await navigate({ to: homeTo })
    } catch (err) {
      setProblem(err instanceof Error ? err.message : 'Something went wrong. Please try again.')
      setBusy(false)
    }
  }

  if (!pending) {
    return (
      <div className="space-y-4">
        <h1 className="text-3xl">{initial.title}</h1>
        <div className="flex items-center gap-2">
          <Badge value={item.status} />
          <span className="text-sm text-ink-2">This draft has already been {item.status}.</span>
        </div>
        {item.reject_reason && <p className="text-ink-2">Reason: {item.reject_reason}</p>}
        {item.result_brief_id && (
          <Link to="/briefs/$briefId" params={{ briefId: item.result_brief_id }} className="btn btn-primary">
            Open the brief
          </Link>
        )}
        <div>
          <Link to={homeTo} className="link-action font-semibold text-primary">
            Back
          </Link>
        </div>
      </div>
    )
  }

  return (
    <div className="space-y-8">
      <div>
        <Link to={homeTo} className="link-action text-sm font-medium text-primary">
          ← Back
        </Link>
        <h1 className="text-3xl">Check your draft</h1>
      </div>

      <div className="card space-y-2 bg-tint/50 p-4 text-sm">
        <p>
          <strong>Drafted by AI</strong> from {sourceLabel(item.source)}. It can misread or guess, so check the site, days, areas and
          minutes before you approve.
        </p>
        <p className="text-ink-2">
          Approving creates a draft brief you can still change area by area. Nothing is sent to vendors until you lock it, and prices
          come from each vendor's rate and these minutes, not from the AI.
        </p>
      </div>

      {(initial.questions.length > 0 || initial.assumptions.length > 0) && (
        <Section title="Worth a look">
          <div className="space-y-2">
            {initial.questions.map((q) => (
              <p key={q} className="rounded-lg bg-alert-bg p-3 text-sm text-alert">
                Please confirm: {q}
              </p>
            ))}
            {initial.assumptions.map((a) => (
              <p key={a} className="rounded-lg bg-line/50 p-3 text-sm text-ink-2">
                Assumed: {a}
              </p>
            ))}
          </div>
        </Section>
      )}

      <Section title="The brief">
        <Field label="Title" htmlFor="title">
          <input id="title" className="field" value={title} maxLength={120} onChange={(e) => setTitle(e.target.value)} disabled={busy || !canReview} />
        </Field>
      </Section>

      <Section title="Where">
        <Field label="Site" htmlFor="site-choice">
          <select id="site-choice" className="field" value={siteChoice} onChange={(e) => setSiteChoice(e.target.value)} disabled={busy || !canReview}>
            <option value="new">A new site (from the draft)</option>
            {sites.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
                {s.postcode ? `, ${s.postcode}` : ''}
              </option>
            ))}
          </select>
        </Field>
        {siteChoice === 'new' && (
          <div className="space-y-3">
            <Field label="Site name" htmlFor="site-name">
              <input id="site-name" className="field" value={site.name} maxLength={120} onChange={(e) => setSite({ ...site, name: e.target.value })} disabled={busy || !canReview} />
            </Field>
            <Field label="Address" htmlFor="site-address">
              <input id="site-address" className="field" value={site.address} maxLength={200} onChange={(e) => setSite({ ...site, address: e.target.value })} disabled={busy || !canReview} />
            </Field>
            <Field label="Postcode" htmlFor="site-postcode" hint="Used to find vendors who cover you and to check cleaners arrive on site.">
              <input id="site-postcode" className="field" value={site.postcode} maxLength={12} onChange={(e) => setSite({ ...site, postcode: e.target.value })} disabled={busy || !canReview} />
            </Field>
            <Field label="Access notes" htmlFor="site-access" hint="Shared only with the vendor you book. Don't put codes here.">
              <textarea id="site-access" className="field min-h-[5rem] py-3" value={site.access_notes} maxLength={500} onChange={(e) => setSite({ ...site, access_notes: e.target.value })} disabled={busy || !canReview} />
            </Field>
          </div>
        )}
      </Section>

      <Section title="When">
        <div className="flex flex-wrap gap-2" role="group" aria-label="Visit days">
          {DAYS.map((d) => (
            <button
              key={d}
              type="button"
              disabled={busy || !canReview}
              aria-pressed={days.includes(d)}
              className={`btn !px-3 text-sm ${days.includes(d) ? 'btn-primary' : 'btn-ghost'}`}
              onClick={() => setDays((cur) => DAYS.filter((x) => (x === d ? !cur.includes(d) : cur.includes(x))))}
            >
              {DAY_LABEL[d]}
            </button>
          ))}
        </div>
        <Field label="Usual start time" htmlFor="start">
          <input id="start" type="time" className="field w-40" value={start} onChange={(e) => setStart(e.target.value)} disabled={busy || !canReview} />
        </Field>
      </Section>

      <Section title={`What gets cleaned · ${totals.areas} areas, ${hoursLabel(totals.minutes)} a visit`}>
        {totals.estimated > 0 && (
          <p className="text-sm text-ink-2">
            {totals.estimated} {totals.estimated === 1 ? 'area has' : 'areas have'} minutes the AI estimated. You can change every area, minute and standard in the brief builder
            next.
          </p>
        )}
        <div className="space-y-4">
          {initial.sections.map((s) => (
            <div key={s.name} className="card divide-y divide-line">
              <p className="p-4 font-semibold">{s.name}</p>
              {s.areas.map((a) => (
                <div key={a.name} className="space-y-1 p-4">
                  <div className="flex items-baseline justify-between gap-3">
                    <p className="font-medium">{a.name}</p>
                    <p className="flex shrink-0 items-center gap-2 text-sm text-ink-2">
                      {a.minutes} min
                      {a.minutes_source === 'estimated' && <Badge value="estimated">Estimated</Badge>}
                    </p>
                  </div>
                  {a.standards.length > 0 ? (
                    <ul className="list-disc space-y-0.5 pl-5 text-sm text-ink-2">
                      {a.standards.map((st) => (
                        <li key={st}>{st}</li>
                      ))}
                    </ul>
                  ) : (
                    <p className="text-sm text-ink-2">No standards drafted: you can add them in the brief builder.</p>
                  )}
                </div>
              ))}
            </div>
          ))}
        </div>
      </Section>

      <ErrorNote message={problem} />
      {!canReview ? (
        <p className="rounded-lg bg-line/50 p-3 text-sm text-ink-2">Only an owner or approver can approve this draft.</p>
      ) : rejecting ? (
        <div className="card space-y-3 p-4">
          <Field label="Why not? (optional)" htmlFor="reason">
            <input id="reason" className="field" value={reason} maxLength={500} onChange={(e) => setReason(e.target.value)} />
          </Field>
          <div className="flex gap-2">
            <button className="btn btn-primary" disabled={busy} onClick={() => void reject()}>
              Reject this draft
            </button>
            <button className="btn btn-ghost" disabled={busy} onClick={() => setRejecting(false)}>
              Not yet
            </button>
          </div>
        </div>
      ) : (
        <div className="flex flex-wrap gap-2">
          <button className="btn btn-primary flex-1" disabled={busy} onClick={() => void approve()}>
            {busy ? 'Creating your brief…' : 'Approve and continue to the brief'}
          </button>
          <button className="btn btn-ghost" disabled={busy} onClick={() => setRejecting(true)}>
            Reject
          </button>
        </div>
      )}
    </div>
  )
}
