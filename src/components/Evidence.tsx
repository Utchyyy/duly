import { useEffect, useState } from 'react'
import { supabase } from '#/lib/supabase'

export type EvidenceRow = { id: string; area_id: string; kind: string; storage_path: string; within_geofence: boolean | null; created_at: string }

/** Signed URLs for a set of evidence rows (the bucket is private). */
export function useSignedUrls(rows: EvidenceRow[] | undefined): Record<string, string> {
  const [urls, setUrls] = useState<Record<string, string>>({})
  const key = (rows ?? []).map((r) => r.storage_path).join('|')
  useEffect(() => {
    const paths = (rows ?? []).map((r) => r.storage_path)
    if (paths.length === 0) return
    supabase()
      .storage.from('evidence')
      .createSignedUrls(paths, 3600)
      .then(({ data }) => {
        const out: Record<string, string> = {}
        for (const d of data ?? []) if (d.path && d.signedUrl) out[d.path] = d.signedUrl
        setUrls(out)
      })
  }, [key])
  return urls
}

export function PhotoStrip({ rows, urls }: { rows: EvidenceRow[]; urls: Record<string, string> }) {
  if (rows.length === 0) return <p className="text-sm text-ink-2">No photos.</p>
  return (
    <div className="flex gap-2 overflow-x-auto pb-1">
      {rows.map((r) => (
        <a key={r.id} href={urls[r.storage_path]} target="_blank" rel="noreferrer" className="relative shrink-0">
          {urls[r.storage_path] ? (
            <img src={urls[r.storage_path]} alt={r.kind === 'photo_before' ? 'Before' : 'After'} className="size-24 rounded-lg object-cover" />
          ) : (
            <div className="size-24 rounded-lg bg-line" />
          )}
          <span className="absolute bottom-1 left-1 rounded bg-ink/70 px-1.5 text-[10px] font-semibold text-white">
            {r.kind === 'photo_before' ? 'Before' : 'After'}
            {r.within_geofence === false ? ' · off site' : ''}
          </span>
        </a>
      ))}
    </div>
  )
}
