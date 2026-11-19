// Feature switches that Duly staff set (Admin > Feature switches). The database enforces buyer_signup; the app hides the
// marketplace and shift screens when those are off. Nothing is removed: switching one back on brings the screens back.
export type FeatureKey = 'buyer_signup' | 'marketplace' | 'shifts'
export type Features = Record<FeatureKey, boolean>

export const FEATURE_TEXT: Record<FeatureKey, { name: string; hint: string }> = {
  buyer_signup: { name: 'Buyer sign-up', hint: 'Anyone can create a buyer organisation. Off: organisations are created by Duly.' },
  marketplace: { name: 'Marketplace', hint: 'Ranked vendor directory and open invitations for buyers. Off: hidden in the app.' },
  shifts: { name: 'Shift exchange', hint: 'Open shifts and the worker pool (WFX). Off: hidden in the app.' },
}

const CLOSED: Features = { buyer_signup: false, marketplace: false, shifts: false }

export function readFeatures(rows: { key: string; enabled: boolean }[] | null | undefined): Features {
  const out = { ...CLOSED }
  for (const r of rows ?? []) if (r.key in out) out[r.key as FeatureKey] = r.enabled
  return out
}
