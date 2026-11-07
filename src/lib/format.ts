import { useCallback, useEffect, useState } from 'react'
import type { DependencyList } from 'react'

export function money(amount: number | null | undefined, currency = 'GBP', locale = 'en-GB'): string {
  if (amount == null) return '–'
  return new Intl.NumberFormat(locale, { style: 'currency', currency }).format(Number(amount))
}

export function when(iso: string | null | undefined): string {
  if (!iso) return '–'
  return new Date(iso).toLocaleString('en-GB', {
    weekday: 'short',
    day: 'numeric',
    month: 'short',
    hour: '2-digit',
    minute: '2-digit',
  })
}

export function day(iso: string | null | undefined): string {
  if (!iso) return '–'
  return new Date(iso).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' })
}

export function label(value: string | null | undefined): string {
  if (!value) return ''
  const s = value.replace(/_/g, ' ')
  return s.charAt(0).toUpperCase() + s.slice(1)
}

/** Load data on mount and when deps change; `reload` re-runs it. */
export function useLoad<T>(fn: () => Promise<T>, deps: DependencyList) {
  const [data, setData] = useState<T | undefined>(undefined)
  const [error, setError] = useState<string | null>(null)
  const [tick, setTick] = useState(0)
  useEffect(() => {
    let live = true
    fn()
      .then((d) => {
        if (live) {
          setData(d)
          setError(null)
        }
      })
      .catch((e: unknown) => {
        if (live) setError(e instanceof Error ? e.message : String(e))
      })
    return () => {
      live = false
    }
  }, [...deps, tick])
  const reload = useCallback(() => setTick((t) => t + 1), [])
  return { data, error, reload }
}

/** Throw Supabase errors so useLoad / try-catch can show them; a missing row is an error too. */
export function must<T>(res: { data: T; error: { message: string } | null }): NonNullable<T> {
  if (res.error) throw new Error(res.error.message)
  if (res.data === null || res.data === undefined) throw new Error('Not found, or you do not have access')
  return res.data
}

/** Throw on error for writes that return no rows. */
export function ok(res: { error: { message: string } | null }): void {
  if (res.error) throw new Error(res.error.message)
}

/** Current position, or nulls if the person declines or the device can't tell. */
export function position(): Promise<{ lat: number | null; lng: number | null }> {
  return new Promise((resolve) => {
    if (typeof navigator === 'undefined' || !('geolocation' in navigator)) {
      resolve({ lat: null, lng: null })
      return
    }
    navigator.geolocation.getCurrentPosition(
      (p) => resolve({ lat: p.coords.latitude, lng: p.coords.longitude }),
      () => resolve({ lat: null, lng: null }),
      { enableHighAccuracy: true, timeout: 10000, maximumAge: 60000 },
    )
  })
}

/** UK postcode lookup (postcodes.io, free and keyless). Returns null if not found. */
export async function lookupPostcode(
  postcode: string,
): Promise<{ lat: number; lng: number; town: string; postcode: string } | null> {
  const res = await fetch(`https://api.postcodes.io/postcodes/${encodeURIComponent(postcode.trim())}`)
  if (!res.ok) return null
  const body = (await res.json()) as {
    result?: { latitude: number; longitude: number; admin_district: string; parish?: string; postcode: string }
  }
  if (!body.result) return null
  return {
    lat: body.result.latitude,
    lng: body.result.longitude,
    town: body.result.admin_district,
    postcode: body.result.postcode,
  }
}
