import { Link, createFileRoute } from '@tanstack/react-router'
import { useState } from 'react'
import type { FormEvent } from 'react'
import { Empty } from '#/components/Shells'
import { ErrorNote, Field, Loading, Section } from '#/components/ui'
import { must, useLoad } from '#/lib/format'
import { supabase } from '#/lib/supabase'
import { useEnterprise } from '#/lib/useEnterprise'

export const Route = createFileRoute('/enterprise/sites')({ component: EnterpriseSites })

function EnterpriseSites() {
  const enterprise = useEnterprise()!
  const { data, error } = useLoad(async () => must(await supabase().from('sites').select('id, name, town, postcode').eq('org_id', enterprise.id).order('created_at')), [enterprise.id])

  if (error) return <ErrorNote message={error} />
  if (!data) return <Loading />

  return (
    <div className="space-y-8">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-3xl">Sites and clients</h1>
          <p className="mt-1 max-w-2xl text-sm text-ink-2">
            Your site portfolio. Give each site's client a login here: a <strong>site manager</strong> can check the work like your own staff, a <strong>viewer</strong> only sees the record. Neither sees money,
            quotes or contracts.
          </p>
        </div>
        {enterprise.canManage && (
          <Link to="/sites/new" search={{ org: enterprise.id }} className="btn btn-primary">
            Add a site or write a brief
          </Link>
        )}
      </div>
      {data.length === 0 ? (
        <Empty title="No sites yet">Add a site and write what the clean should achieve there. Then appoint a vendor from your roster.</Empty>
      ) : (
        data.map((s) => <SiteCard key={s.id} site={s} canManage={enterprise.canManage} />)
      )}
    </div>
  )
}

type Access = { user_id: string; email: string; full_name: string | null; role: string }

function SiteCard({ site, canManage }: { site: { id: string; name: string; town: string | null; postcode: string | null }; canManage: boolean }) {
  const { data, error, reload } = useLoad(async (): Promise<Access[]> => (canManage ? must(await supabase().rpc('site_access_list', { p_site: site.id })) : []), [site.id, canManage])
  const [email, setEmail] = useState('')
  const [role, setRole] = useState<'manager' | 'viewer'>('manager')
  const [busy, setBusy] = useState(false)
  const [actionError, setActionError] = useState<string | null>(null)

  async function grant(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setActionError(null)
    const { error: err } = await supabase().rpc('grant_site_access', { p_site: site.id, p_email: email.trim(), p_role: role })
    setBusy(false)
    if (err) return setActionError(err.message)
    setEmail('')
    reload()
  }

  async function revoke(userId: string) {
    setActionError(null)
    const { error: err } = await supabase().rpc('revoke_site_access', { p_site: site.id, p_user: userId })
    if (err) return setActionError(err.message)
    reload()
  }

  return (
    <Section title={site.name}>
      <div className="card space-y-3 p-4">
        <p className="text-sm text-ink-2">{[site.town, site.postcode].filter(Boolean).join(' ')}</p>
        <ErrorNote message={error ?? actionError} />
        {canManage ? (
          <>
            <p className="text-sm font-medium">Who can see this site</p>
            {!data ? (
              <Loading />
            ) : data.length === 0 ? (
              <p className="text-sm text-ink-2">Nobody outside your organisation yet.</p>
            ) : (
              <ul className="divide-y divide-line">
                {data.map((a) => (
                  <li key={a.user_id} className="flex flex-wrap items-center justify-between gap-2 py-1 text-sm">
                    <span>
                      {a.full_name ? `${a.full_name} · ` : ''}
                      {a.email} · <span className="font-medium">{a.role === 'manager' ? 'Site manager' : 'Viewer'}</span>
                    </span>
                    <button className="btn btn-ghost text-sm" onClick={() => void revoke(a.user_id)} aria-label={`Remove access for ${a.email}`}>
                      Remove
                    </button>
                  </li>
                ))}
              </ul>
            )}
            <form onSubmit={grant} className="flex flex-wrap items-end gap-2">
              <Field label="Their email" htmlFor={`email-${site.id}`}>
                <input id={`email-${site.id}`} type="email" required className="field min-w-[16rem]" value={email} onChange={(e) => setEmail(e.target.value)} />
              </Field>
              <Field label="Access" htmlFor={`role-${site.id}`}>
                <select id={`role-${site.id}`} className="field w-auto" value={role} onChange={(e) => setRole(e.target.value as 'manager' | 'viewer')}>
                  <option value="manager">Site manager (checks the work)</option>
                  <option value="viewer">Viewer (sees the record)</option>
                </select>
              </Field>
              <button className="btn btn-primary" disabled={busy || !email.trim()}>
                Give access
              </button>
            </form>
            <p className="text-xs text-ink-2">They need an account first: ask them to sign in once on Duly. It shows them nothing until you give access here.</p>
          </>
        ) : (
          <p className="text-sm text-ink-2">Only your organisation's owner or approvers manage who can see a site.</p>
        )}
      </div>
    </Section>
  )
}
