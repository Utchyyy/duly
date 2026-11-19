// Rules for the document behind a verification claim: what may be attached and where it is stored. Pure, so it can be tested.
// The database holds the real limits (the bucket's size and type list, and the path a claim may point at); this keeps people from
// finding out only after an upload fails.

export const CLAIM_FILE_MAX_BYTES = 10 * 1024 * 1024
export const CLAIM_FILE_TYPES = ['application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'image/heic'] as const
export const CLAIM_FILE_ACCEPT = '.pdf,.jpg,.jpeg,.png,.webp,.heic,application/pdf,image/jpeg,image/png,image/webp,image/heic'

const EXTENSION_TYPES: Record<string, string> = { pdf: 'application/pdf', jpg: 'image/jpeg', jpeg: 'image/jpeg', png: 'image/png', webp: 'image/webp', heic: 'image/heic' }

/** The type to trust: the browser's, or else from the file's extension (some browsers give none for .heic). */
export function claimFileType(file: { name: string; type: string }): string {
  if (file.type) return file.type
  return EXTENSION_TYPES[(file.name.split('.').pop() ?? '').toLowerCase()] ?? ''
}

/** A reason the file cannot be attached, or null when it can. */
export function checkClaimFile(file: { name: string; size: number; type: string }): string | null {
  if (file.size <= 0) return 'That file is empty.'
  if (file.size > CLAIM_FILE_MAX_BYTES) return 'That file is over 10 MB. Send a smaller copy.'
  if (!(CLAIM_FILE_TYPES as readonly string[]).includes(claimFileType(file))) return 'Attach a PDF or a photo (JPG, PNG, WebP or HEIC).'
  return null
}

/** A file name that is safe in a storage path: lower case, letters, digits, dots, dashes, at most 80 characters, keeping its extension. */
export function safeFileName(full: string): string {
  const name = full.split(/[\\/]/).pop() ?? ''
  const dot = name.lastIndexOf('.')
  const ext = dot > 0 ? name.slice(dot + 1).toLowerCase().replace(/[^a-z0-9]/g, '').slice(0, 5) : ''
  const base = (dot > 0 ? name.slice(0, dot) : name).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 60)
  return `${base || 'document'}${ext ? `.${ext}` : ''}`
}

/** Where a claim's document goes: <vendor id>/<claim id>/<time>-<name>. The time keeps a replacement from clashing with the file it replaces. */
export function claimFilePath(orgId: string, claimId: string, fileName: string, at = Date.now()): string {
  return `${orgId}/${claimId}/${at}-${safeFileName(fileName)}`
}

/** The name to show for a stored path: the file name without its folders or timestamp. */
export function claimFileLabel(path: string | null | undefined): string {
  if (!path) return ''
  const last = path.split('/').pop() ?? ''
  return last.replace(/^\d{10,}-/, '')
}
