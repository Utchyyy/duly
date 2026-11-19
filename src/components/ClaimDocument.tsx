import { useState } from 'react'
import { claimFileLabel } from '#/lib/claimEvidence'
import { openClaimDocument } from '#/lib/claimEvidenceClient'

/** A claim's document: its name and a button that opens it in a new tab. */
export function ClaimDocument({ path, className = '' }: { path: string; className?: string }) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  async function open() {
    setBusy(true)
    setError(null)
    setError(await openClaimDocument(path))
    setBusy(false)
  }
  return (
    <span className={`inline-flex flex-wrap items-center gap-2 ${className}`}>
      <button type="button" className="btn btn-ghost text-sm" disabled={busy} onClick={() => void open()} aria-label={`View document ${claimFileLabel(path)}`}>
        View document
      </button>
      <span className="text-xs text-ink-2">{claimFileLabel(path)}</span>
      {error && <span className="text-xs text-alert">{error}</span>}
    </span>
  )
}
