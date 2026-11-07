import { createClient } from '@supabase/supabase-js'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from './database.types'

export type Duly = SupabaseClient<Database>

const DEFAULT_URL = 'https://mnlyltdxnvzbttugkmng.supabase.co'
const DEFAULT_PUBLISHABLE = 'sb_publishable_dAgs_1vEd3046QRq7TZrUg_-JTERFrF'

let client: Duly | undefined

/** The public URL and publishable key. Both are safe in the browser; env vars override the defaults. */
export function supabaseConfig(): { url: string; key: string } {
  return {
    url: import.meta.env.VITE_SUPABASE_URL || DEFAULT_URL,
    key: import.meta.env.VITE_SUPABASE_PUBLISHABLE || DEFAULT_PUBLISHABLE,
  }
}

/** Browser-only Supabase client. Session lives in the browser; pages that need it render on the client. */
export function supabase(): Duly {
  if (typeof window === 'undefined') {
    throw new Error('supabase() is browser-only')
  }
  if (!client) {
    const { url, key } = supabaseConfig()
    client = createClient<Database>(url, key, {
      auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
    })
  }
  return client
}
