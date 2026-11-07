import { DraftError, LIMITS, sanitiseDraft } from './brief-draft.ts'
import type { BriefDraft } from './brief-draft.ts'

export const SOURCE_TYPES = {
  pdf: 'application/pdf',
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  png: 'image/png',
  webp: 'image/webp',
  txt: 'text/plain',
} as const
export type SourceMime = (typeof SOURCE_TYPES)[keyof typeof SOURCE_TYPES]

export type SourceFile = { path: string; mime: SourceMime; bytes: Uint8Array }
export type GenerateParams = { text: string; file: SourceFile | null }
export type Generated = { raw: unknown; model: string; usage?: { input_tokens: number; output_tokens: number } }

/** Everything the pipeline touches outside itself. The real ones live in run-draft.server.ts. */
export type DraftDeps = {
  /** Ask the model for a draft. Returns its raw, unvalidated output. */
  generate: (params: GenerateParams) => Promise<Generated>
  /** The signed-in person's roles in the organisation. */
  rolesIn: (orgId: string) => Promise<string[]>
  /** Read an uploaded source document (as the signed-in person, so storage rules apply). */
  download: (path: string) => Promise<SourceFile>
  /** Add the pending draft to approval_queue (as the signed-in person) and return its id. */
  addToQueue: (row: { org_id: string; source: Record<string, unknown>; draft: BriefDraft }) => Promise<string>
  now: () => Date
}

export type DraftRequest = { orgId: string; text?: string; filePath?: string }

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export function mimeFor(path: string): SourceMime | null {
  const ext = path.split('.').pop()?.toLowerCase() ?? ''
  return (SOURCE_TYPES as Record<string, SourceMime>)[ext] ?? null
}

/**
 * Draft a brief from pasted text and/or an uploaded document, and queue it for a person to approve.
 * The only thing this writes is one pending row in approval_queue: no site, brief, quote, price or ranking.
 */
export async function createBriefDraft(deps: DraftDeps, req: DraftRequest): Promise<{ id: string }> {
  if (!UUID.test(req.orgId)) throw new DraftError('invalid_input', 'That organisation is not valid.')
  const text = (req.text ?? '').trim()
  const filePath = req.filePath?.trim() || null
  if (!text && !filePath) throw new DraftError('invalid_input', 'Paste a description or upload a document to draft from.')
  if (text.length > LIMITS.inputText) {
    throw new DraftError('invalid_input', `That is too long to draft from. Keep it under ${LIMITS.inputText.toLocaleString('en-GB')} characters, or upload it as a file.`)
  }
  if (filePath) {
    // Uploads live under <organisation id>/...; refuse anything else before fetching it.
    if (!filePath.startsWith(`${req.orgId}/`) || filePath.includes('..')) throw new DraftError('invalid_input', 'That file is not in your organisation.')
    if (!mimeFor(filePath)) throw new DraftError('invalid_input', 'Upload a PDF, a photo (JPEG, PNG or WebP) or a text file.')
  }

  // Only the organisation's owners and approvers can ask for a draft; check before spending on the model.
  const roles = await deps.rolesIn(req.orgId)
  if (!roles.some((r) => r === 'owner' || r === 'approver')) {
    throw new DraftError('forbidden', 'Only an owner or approver can draft a brief for this organisation.')
  }

  const file = filePath ? await deps.download(filePath) : null
  const generated = await deps.generate({ text, file })
  const draft = sanitiseDraft(generated.raw)

  const id = await deps.addToQueue({
    org_id: req.orgId,
    source: {
      generated_by: 'ai',
      model: generated.model,
      requested_at: deps.now().toISOString(),
      file_path: file?.path ?? null,
      file_type: file?.mime ?? null,
      text: text || null,
      usage: generated.usage ?? null,
    },
    draft,
  })
  return { id }
}
