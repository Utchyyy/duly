import { useEffect, useState } from 'react'
import { supabase } from '#/lib/supabase'

type Vendor = {
  id: string
  name: string
  verification_tier: number
  vendor_profiles: { description: string | null; service_radius_km: number; hourly_rate: number | null } | null
  vendor_scores: { quality_score: number | null; jobs_completed: number } | null
}

const tierLabel = ['Unverified', 'ID checked', 'Insured and checked', 'Fully verified']

/**
 * Directory of vendors, alphabetical. This is not a ranking: ranked results come from the
 * rank_vendors() SQL function once a site is added, and the frontend never re-sorts them.
 */
export function VendorDirectory() {
  const [vendors, setVendors] = useState<Vendor[] | null>(null)

  useEffect(() => {
    supabase()
      .from('organisations')
      .select(
        'id, name, verification_tier, vendor_profiles(description, service_radius_km, hourly_rate), vendor_scores(quality_score, jobs_completed)',
      )
      .eq('kind', 'vendor')
      .order('name')
      .then(({ data }) => setVendors((data ?? []) as unknown as Vendor[]))
  }, [])

  if (!vendors) return <p className="text-ink-2">Loading vendors…</p>

  return (
    <ul className="space-y-3">
      {vendors.map((v) => (
        <li key={v.id} className="card p-4">
          <div className="flex items-start justify-between gap-3">
            <div>
              <p className="font-semibold">{v.name}</p>
              <p className="mt-0.5 text-sm text-ink-2">{v.vendor_profiles?.description}</p>
            </div>
            <span
              className={`shrink-0 rounded-full px-2.5 py-1 text-xs font-semibold ${
                v.verification_tier >= 1 ? 'bg-tint text-primary' : 'bg-alert-bg text-alert'
              }`}
            >
              {tierLabel[v.verification_tier] ?? 'Unverified'}
            </span>
          </div>
          <p className="mt-2 text-sm text-ink-2">
            {v.vendor_scores?.quality_score != null
              ? `Quality ${v.vendor_scores.quality_score} · ${v.vendor_scores.jobs_completed} jobs`
              : 'No completed jobs on Duly yet'}
            {v.vendor_profiles ? ` · covers ${v.vendor_profiles.service_radius_km} km` : ''}
          </p>
        </li>
      ))}
    </ul>
  )
}
