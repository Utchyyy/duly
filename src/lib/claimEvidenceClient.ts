// Adding, replacing, removing and opening the document behind a verification claim. The rules (what may be attached, where it is stored)
// are in claimEvidence.ts and in the database; this is the part that talks to storage.
import { checkClaimFile, claimFilePath, claimFileType } from './claimEvidence.ts'
import { supabase } from './supabase'

const BUCKET = 'claim-evidence'

/** Puts a file under a claim and points the claim at it, then removes the file it replaces. Returns a plain message if something failed. */
export async function attachClaimDocument(orgId: string, claimId: string, file: File, previousPath?: string | null): Promise<string | null> {
  const problem = checkClaimFile(file)
  if (problem) return problem
  const db = supabase()
  const path = claimFilePath(orgId, claimId, file.name)
  const up = await db.storage.from(BUCKET).upload(path, file, { contentType: claimFileType(file), upsert: false })
  if (up.error) return 'The document did not upload. Check your connection and try again.'
  const set = await db.from('verification_claims').update({ evidence_path: path }).eq('id', claimId)
  if (set.error) {
    await db.storage.from(BUCKET).remove([path])
    return 'The document could not be attached to this claim. It may already have been checked.'
  }
  if (previousPath) await db.storage.from(BUCKET).remove([previousPath])
  return null
}

/** Takes the document off a claim and deletes the file. */
export async function removeClaimDocument(claimId: string, path: string): Promise<string | null> {
  const db = supabase()
  const set = await db.from('verification_claims').update({ evidence_path: null }).eq('id', claimId)
  if (set.error) return 'The document could not be removed. It may already have been checked.'
  await db.storage.from(BUCKET).remove([path])
  return null
}

/** Opens a claim's document in a new tab through a link that works for a minute. The tab is opened first so a pop-up blocker lets it through. */
export async function openClaimDocument(path: string): Promise<string | null> {
  const tab = window.open('', '_blank')
  if (!tab) return 'Your browser blocked the new tab. Allow pop-ups for Duly and try again.'
  const { data, error } = await supabase().storage.from(BUCKET).createSignedUrl(path, 60)
  if (error || !data) {
    tab.close()
    return 'The document could not be opened. Try again.'
  }
  tab.opener = null
  tab.location.href = data.signedUrl
  return null
}
