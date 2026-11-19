import { useEffect, useState } from 'react'
import { useAuth } from './auth'
import { readFeatures } from './features'
import type { Features } from './features'
import { supabase } from './supabase'

const CLOSED: Features = { buyer_signup: false, marketplace: false, shifts: false }

/** Fails closed: until the switches load, or if they cannot be read, the screens behind them stay hidden. */
export function useFeatures(): { ready: boolean; features: Features; reload: () => void } {
  const { session } = useAuth()
  const userId = session?.user.id ?? null
  const [features, setFeatures] = useState<Features>(CLOSED)
  const [ready, setReady] = useState(false)
  const [tick, setTick] = useState(0)

  useEffect(() => {
    if (!userId) {
      setFeatures(CLOSED)
      setReady(true)
      return
    }
    let live = true
    void supabase()
      .from('app_features')
      .select('key, enabled')
      .then(({ data, error }) => {
        if (!live) return
        setFeatures(error ? CLOSED : readFeatures(data))
        setReady(true)
      })
    return () => {
      live = false
    }
  }, [userId, tick])

  return { ready, features, reload: () => setTick((n) => n + 1) }
}
