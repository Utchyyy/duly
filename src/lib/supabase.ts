import { createClient } from '@supabase/supabase-js'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from './database.types'

export type Duly = SupabaseClient<Database>

const DEFAULT_URL = 'https://mnlyltdxnvzbttugkmng.supabase.co'
const DEFAULT_PUBLISHABLE = 'sb_publishable_dAgs_1vEd3046QRq7TZrUg_-JTERFrF'

let client: Duly | undefined

/** Browser-only Supabase client. Session lives in the browser; pages that need it render on the client. */
export function supabase(): Duly {
  if (typeof window === 'undefined') {
    throw new Error('supabase() is browser-only')
  }
  if (!client) {
    // Both values are public (the browser needs them). Environment variables override the defaults.
    const url = import.meta.env.VITE_SUPABASE_URL || DEFAULT_URL
    const key = import.meta.env.VITE_SUPABASE_PUBLISHABLE || DEFAULT_PUBLISHABLE
    client = createClient<Database>(url, key, {
      auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
    })
  }
  return client
}
