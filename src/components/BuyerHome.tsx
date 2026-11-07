import { Link } from '@tanstack/react-router'
import { useEffect, useState } from 'react'
import type { FormEvent } from 'react'
import { hasRole, useAuth } from '#/lib/auth'
import { label, money, must, useLoad, when } from '#/lib/format'
import { supabase } from '#/lib/supabase'
import { Empty } from './Shells'
import { TeamManager } from './TeamManager'
import { Badge, ErrorNote, Loading, Section, Table } from './ui'
import { VendorDirectory } from './VendorDirectory'

type Segment = { code: string; name: string }

/** Links to the other areas this person can use. */
export function AreaLinks() {
  const { memberships, hasWorkerRecord } = useAuth()
  const links: { to: string; text: string }[] = []
  if (hasRole(memberships, ['vendor_admin', 'dispatcher'])) links.push({ to: '/pro', text: 'Duly Pro' })
  if (hasWorkerRecord || hasRole(memberships, ['operative'])) links.push({ to: '/crew', text: 'Duly Crew' })
  if (hasRole(memberships, ['platform_admin'])) links.push({ to: '/admin', text: 'Duly Admin' })
  if (memberships.some((m) => m.org?.kind === 'buyer' && m.org.segment !== 'homeowner')) links.push({ to: '/business', text: 'Business' })
  if (memberships.some((m) => m.org?.kind === 'buyer' && m.org.segment === 'homeowner')) links.push({ to: '/', text: 'Home' })
  if (links.length < 2) return null
  return (
    <div className="flex flex-wrap gap-2">
      {links.map((l) => (
        <Link key={l.to} to={l.to} className="btn btn-ghost text-sm" activeOptions={{ exact: true }} activeProps={{ className: '!bg-tint !text-primary' }}>
          {l.text}
        </Link>
      ))}
    </div>
  )
}

function draftTitle(draft: unknown): string {
  const t = draft && typeof draft === 'object' && !Array.isArray(draft) ? (draft as Record<string, unknown>).title : null
  return typeof t === 'string' && t.trim() ? t : 'Untitled draft'
}

/** Home for buyers. `mode` decides which segments an account can be started in. */
export function BuyerHome({ mode }: { mode: 'home' | 'business' }) {
  const { memberships, refresh } = useAuth()
  const buyerOrgs = memberships.filter(
    (m) =>
      m.org?.kind === 'buyer' &&
      (mode === 'home' ? m.org.segment === 'homeowner' : m.org.segment !== 'homeowner'),
  )
  const org = buyerOrgs[0]?.org ?? null

  if (!org) {
    return (
      <div className="space-y-6">
        <AreaLinks />
        <StartAccount mode={mode} onDone={refresh} />
      </div>
    )
  }
  const isOwner = buyerOrgs.some((m) => m.org?.id === org.id && m.role === 'owner')
  return <BuyerDashboard orgId={org.id} orgName={org.name} mode={mode} isOwner={isOwner} />
}

function BuyerDashboard({ orgId, orgName, mode, isOwner }: { orgId: string; orgName: string; mode: 'home' | 'business'; isOwner: boolean }) {
  const { data, error } = useLoad(async () => {
    const db = supabase()
    const [sites, briefs, jobs, toReview, perJob, perContract, drafts] = await Promise.all([
      db.from('sites').select('id, name, town, postcode').eq('org_id', orgId).order('created_at'),
      db.from('briefs').select('id, title, status, current_version, site_id, created_at').eq('buyer_org_id', orgId).order('created_at', { ascending: false }),
      db
        .from('jobs')
        .select('id, status, scheduled_start, site_id, vendor:organisations!jobs_vendor_org_id_fkey(name)')
        .eq('buyer_org_id', orgId)
        .order('scheduled_start', { ascending: false })
        .limit(20),
      // Cleans the crew has finished and the client has not yet checked. Money is only released once they approve, so these
      // are never hidden by the 20-job limit above and are shown first.
      db
        .from('jobs')
        .select('id, status, scheduled_start, site_id, vendor:organisations!jobs_vendor_org_id_fkey(name)')
        .eq('buyer_org_id', orgId)
        .eq('status', 'completed')
        .order('scheduled_start'),
      db
        .from('payments')
        .select('id, kind, amount, currency, due_at, note, job:jobs!inner(buyer_org_id)')
        .eq('job.buyer_org_id', orgId)
        .eq('kind', 'escrow_hold')
        .eq('status', 'pending'),
      db
        .from('payments')
        .select('id, kind, amount, currency, due_at, note, contract:contracts!inner(buyer_org_id)')
        .eq('contract.buyer_org_id', orgId)
        .in('kind', ['direct_debit', 'invoice'])
        .eq('status', 'pending'),
      db.from('approval_queue').select('id, draft, created_at').eq('org_id', orgId).eq('kind', 'brief_draft').eq('status', 'pending').order('created_at', { ascending: false }),
    ])
    const toPay = [...must(perJob), ...must(perContract)].sort((a, b) => (a.due_at ?? '').localeCompare(b.due_at ?? ''))
    return { sites: must(sites), briefs: must(briefs), jobs: must(jobs), toReview: must(toReview), toPay, drafts: must(drafts) }
  }, [orgId])

  const { memberships } = useAuth()
  const canDraft = memberships.some((m) => m.org_id === orgId && (m.role === 'owner' || m.role === 'approver'))
  const siteName = (id: string) => data?.sites.find((s) => s.id === id)?.name ?? ''
  const place = mode === 'home' ? 'home' : 'site'

  return (
    <div className="space-y-8">
      <AreaLinks />
      <section className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <p className="text-sm font-medium text-primary">{orgName}</p>
          <h1 className="mt-1 text-3xl">{mode === 'home' ? 'Your home' : 'Your sites'}</h1>
        </div>
        <div className="flex flex-wrap gap-2">
          {canDraft && (
            <Link to="/drafts/new" search={{ org: orgId }} className="btn btn-ghost">
              Draft from a document
            </Link>
          )}
          <Link to="/sites/new" search={{ org: orgId }} className="btn btn-primary">
            {data?.sites.length ? `New brief` : `Add your ${place}`}
          </Link>
        </div>
      </section>
      <ErrorNote message={error} />
      {!data ? (
        <Loading />
      ) : (
        <>
          {data.drafts.length > 0 && (
            <Section title="Drafts to review">
              <ul className="space-y-2">
                {data.drafts.map((d) => (
                  <li key={d.id}>
                    <Link to="/drafts/$itemId" params={{ itemId: d.id }} className="card flex items-center justify-between gap-3 p-4">
                      <div>
                        <p className="font-semibold">{draftTitle(d.draft)}</p>
                        <p className="text-sm text-ink-2">Drafted by AI · {when(d.created_at)} · check it before approving</p>
                      </div>
                      <Badge value="pending">Review</Badge>
                    </Link>
                  </li>
                ))}
              </ul>
            </Section>
          )}
          {data.toReview.length > 0 && (
            <Section title="Check the work">
              <p className="text-sm text-ink-2">The cleaner has finished. Look at the photos and mark each standard. Money is only released once you approve.</p>
              <ul className="space-y-2">
                {data.toReview.map((j) => (
                  <li key={j.id}>
                    <Link to="/jobs/$jobId" params={{ jobId: j.id }} className="card flex items-center justify-between gap-3 border-primary p-4">
                      <div>
                        <p className="font-semibold">{when(j.scheduled_start)}</p>
                        <p className="text-sm text-ink-2">
                          {j.vendor?.name} · {siteName(j.site_id)}
                        </p>
                      </div>
                      <Badge value="completed">Check the work</Badge>
                    </Link>
                  </li>
                ))}
              </ul>
            </Section>
          )}
          <Section title="Cleans booked">
            {data.jobs.length === 0 ? (
              <Empty title="Nothing booked yet">Accept a quote on a brief and the clean appears here.</Empty>
            ) : (
              <ul className="space-y-2">
                {data.jobs.map((j) => (
                  <li key={j.id}>
                    <Link to="/jobs/$jobId" params={{ jobId: j.id }} className="card flex items-center justify-between gap-3 p-4">
                      <div>
                        <p className="font-semibold">{when(j.scheduled_start)}</p>
                        <p className="text-sm text-ink-2">
                          {j.vendor?.name} · {siteName(j.site_id)}
                        </p>
                      </div>
                      <Badge value={j.status} />
                    </Link>
                  </li>
                ))}
              </ul>
            )}
          </Section>
          <Section title="Briefs">
            {data.briefs.length === 0 ? (
              <Empty title="No briefs yet">
                Add your {place}, pick a starting schedule and adjust it. Lock it when it's right to get ranked vendors and quotes.
              </Empty>
            ) : (
              <ul className="space-y-2">
                {data.briefs.map((b) => (
                  <li key={b.id}>
                    <Link to="/briefs/$briefId" params={{ briefId: b.id }} className="card flex items-center justify-between gap-3 p-4">
                      <div>
                        <p className="font-semibold">{b.title}</p>
                        <p className="text-sm text-ink-2">
                          {siteName(b.site_id)} · version {b.current_version}
                        </p>
                      </div>
                      <Badge value={b.status}>{b.status === 'draft' ? 'Draft' : label(b.status)}</Badge>
                    </Link>
                  </li>
                ))}
              </ul>
            )}
          </Section>
          {data.toPay.length > 0 && (
            <Section title="To pay">
              <p className="text-sm text-ink-2">
                Pay by bank transfer to Duly using the reference we send you. Card and Direct Debit payments are coming. Money for a
                clean only reaches the vendor once you've approved the work.
              </p>
              <Table head={['What', 'Amount', 'Due']}>
                {data.toPay.map((p) => (
                  <tr key={p.id}>
                    <td>{p.note ?? label(p.kind)}</td>
                    <td>{money(p.amount, p.currency)}</td>
                    <td>{when(p.due_at)}</td>
                  </tr>
                ))}
              </Table>
            </Section>
          )}
          {mode === 'business' && (
            <Section title="Your team">
              <TeamManager
                orgId={orgId}
                roles={['approver', 'viewer', 'owner']}
                canAdd={isOwner}
                hint="Approvers can book cleans, review work and report problems. Viewers can see everything. Ask them to sign in to Duly once first."
              />
            </Section>
          )}
          <Section title="Vendors on Duly">
            <VendorDirectory />
          </Section>
        </>
      )}
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
      <ErrorNote message={error} />
    </form>
  )
}
