import { createClient } from '@supabase/supabase-js'
import type { Database, Json } from '../database.types.ts'
import { supabaseConfig } from '../supabase.ts'
import { anthropicGenerator } from './anthropic.server.ts'
import { DraftError } from './brief-draft.ts'
import { createBriefDraft, mimeFor } from './create-draft.ts'
import type { DraftDeps, DraftRequest } from './create-draft.ts'

export type DraftCall = DraftRequest & { accessToken: string }

/**
 * Server only. Acts as the signed-in person: every database and storage call carries their token, so row-level
 * security and the storage rules apply exactly as if they had made the call themselves. The model's output is
 * written to approval_queue and nowhere else.
 */
export async function runBriefDraft(call: DraftCall): Promise<{ id: string }> {
  const { url, key } = supabaseConfig()
  const db = createClient<Database>(url, key, {
    global: { headers: { Authorization: `Bearer ${call.accessToken}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  })
  const { data: auth, error: authError } = await db.auth.getUser(call.accessToken)
  if (authError || !auth.user) throw new DraftError('forbidden', 'Please sign in again.')
  const userId = auth.user.id

  const deps: DraftDeps = {
    generate: anthropicGenerator(),
    now: () => new Date(),
    async rolesIn(orgId) {
      const { data, error } = await db.from('memberships').select('role').eq('org_id', orgId).eq('user_id', userId)
      if (error) throw new DraftError('forbidden', 'We could not check your access.')
      return (data ?? []).map((m) => m.role)
    },
    async download(path) {
      const mime = mimeFor(path)
      if (!mime) throw new DraftError('invalid_input', 'That file type is not supported.')
      const { data, error } = await db.storage.from('brief-sources').download(path)
      if (error || !data) throw new DraftError('invalid_input', 'We could not open that file. Upload it again.')
      return { path, mime, bytes: new Uint8Array(await data.arrayBuffer()) }
    },
    async addToQueue(row) {
      const { data, error } = await db
        .from('approval_queue')
        .insert({ org_id: row.org_id, source: row.source as Json, draft: row.draft as unknown as Json })
        .select('id')
        .single()
      if (error || !data) {
        // The database enforces the limits and who may add drafts; show its reason where it is safe to.
        const known = /Too many drafts|Daily drafting limit/.exec(error?.message ?? '')
        throw new DraftError(known ? 'unavailable' : 'forbidden', known ? (error?.message ?? 'Try again later.') : 'You cannot add drafts for this organisation.')
      }
      return data.id
    },
  }
  return createBriefDraft(deps, { orgId: call.orgId, text: call.text, filePath: call.filePath })
}
