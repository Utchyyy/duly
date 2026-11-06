import { createClient } from '@supabase/supabase-js'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from './database.types'

export type Duly = SupabaseClient<Database>

let client: Duly | undefined

/** Browser-only Supabase client. Session lives in the browser; pages that need it render on the client. */
export function supabase(): Duly {
  if (typeof window === 'undefined') {
    throw new Error('supabase() is browser-only')
  }
  if (!client) {
    const url = import.meta.env.VITE_SUPABASE_URL
    const key = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY
    if (!url || !key) {
      throw new Error('Set VITE_SUPABASE_URL and VITE_SUPABASE_PUBLISHABLE_KEY')
    }
    client = createClient<Database>(url, key, {
      auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
    })
  }
  return client
}
