import { Link, createFileRoute, useNavigate } from '@tanstack/react-router'
import { useState } from 'react'
import type { FormEvent } from 'react'
import { Gate } from '#/components/Gate'
import { AppShell } from '#/components/Shells'
import { ErrorNote, Field } from '#/components/ui'
import { useAuth } from '#/lib/auth'
import { LIMITS } from '#/lib/drafting/brief-draft'
import { draftBrief } from '#/lib/drafting/draft-brief.fn'
import { supabase } from '#/lib/supabase'

export const Route = createFileRoute('/drafts/new')({
  validateSearch: (s: Record<string, unknown>) => ({ org: typeof s.org === 'string' ? s.org : '' }),
  head: () => ({ meta: [{ title: 'Draft a brief · Duly' }] }),
  component: NewDraftPage,
})

function NewDraftPage() {
  return (
    <AppShell>
      <Gate allowSignUp signInHeading="Sign in">
        <NewDraft />
      </Gate>
    </AppShell>
  )
}

const MAX_FILE_BYTES = 10 * 1024 * 1024
const ACCEPT = '.pdf,.jpg,.jpeg,.png,.webp,.txt,application/pdf,image/jpeg,image/png,image/webp,text/plain'

function safeName(name: string): string {
  const ext = (name.split('.').pop() ?? '').toLowerCase().replace(/[^a-z0-9]/g, '')
  const stem = name.replace(/\.[^.]*$/, '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 40) || 'document'
  return `${stem}.${ext || 'pdf'}`
}

function NewDraft() {
  const { org: orgParam } = Route.useSearch()
  const { memberships } = useAuth()
  const navigate = useNavigate()
  const member = memberships.find(
    (m) => m.org?.kind === 'buyer' && (!orgParam || m.org.id === orgParam) && (m.role === 'owner' || m.role === 'approver'),
  )
  const org = member?.org ?? null

  const [text, setText] = useState('')
  const [file, setFile] = useState<File | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  if (!org) {
    return (
      <div className="space-y-4">
        <h1 className="text-3xl">Draft a brief</h1>
        <ErrorNote message="Only an owner or approver of a home or business can draft a brief. Set one up first." />
        <Link to="/" className="btn btn-ghost">
          Back
        </Link>
      </div>
    )
  }

  async function submit(e: FormEvent) {
    e.preventDefault()
    if (!org) return
    setError(null)
    if (!text.trim() && !file) return setError('Paste a description or choose a document to draft from.')
    if (file && file.size > MAX_FILE_BYTES) return setError('That file is over 10 MB. Try a smaller one.')
    setBusy(true)
    try {
      const db = supabase()
      let filePath: string | undefined
      if (file) {
        filePath = `${org.id}/${Date.now()}-${safeName(file.name)}`
        const up = await db.storage.from('brief-sources').upload(filePath, file, { contentType: file.type || undefined })
        if (up.error) throw new Error('We could not upload that file. Check it is a PDF, photo or text file under 10 MB.')
      }
      const { data } = await db.auth.getSession()
      if (!data.session) throw new Error('Please sign in again.')
      const { id } = await draftBrief({ data: { accessToken: data.session.access_token, orgId: org.id, text: text.trim() || undefined, filePath } })
      await navigate({ to: '/drafts/$itemId', params: { itemId: id } })
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Drafting failed. Please try again.')
      setBusy(false)
    }
  }

  return (
    <form onSubmit={submit} className="space-y-6">
      <div>
        <Link to={org.segment === 'homeowner' ? '/' : '/business'} className="text-sm font-medium text-primary">
          ← Back
        </Link>
        <h1 className="mt-2 text-3xl">Draft a brief</h1>
        <p className="mt-2 text-ink-2">
          Paste a description, or upload a cleaning specification, tender or photo of your checklist. An AI assistant drafts the areas,
          minutes and standards. <strong>It is only a draft:</strong> nothing is created until you check it and approve it, and you
          decide when to lock the brief and ask for quotes.
        </p>
      </div>

      <Field label="Describe the job" htmlFor="material" hint={`Up to ${LIMITS.inputText.toLocaleString('en-GB')} characters. Leave out passwords and door codes.`}>
        <textarea
          id="material"
          className="field min-h-[10rem] py-3"
          maxLength={LIMITS.inputText}
          value={text}
          disabled={busy}
          onChange={(e) => setText(e.target.value)}
          placeholder="e.g. Two-surgery dental practice in Colchester, cleaned Tuesday and Thursday evenings from 6pm. Surgeries need disinfecting, waiting room hoovered…"
        />
      </Field>

      <Field label="Or upload a document" htmlFor="source" hint="PDF, photo (JPEG, PNG, WebP) or text file, up to 10 MB.">
        <input
          id="source"
          type="file"
          accept={ACCEPT}
          disabled={busy}
          className="field py-2.5"
          onChange={(e) => setFile(e.target.files?.[0] ?? null)}
        />
      </Field>

      <ErrorNote message={error} />
      <button className="btn btn-primary w-full" disabled={busy}>
        {busy ? 'Reading it and drafting… this can take a minute' : 'Draft with AI'}
      </button>
      <p className="text-center text-sm text-ink-2">
        Prefer to start from scratch?{' '}
        <Link to="/sites/new" search={{ org: org.id }} className="link-action font-semibold text-primary">
          Start a brief by hand
        </Link>
      </p>
    </form>
  )
}
