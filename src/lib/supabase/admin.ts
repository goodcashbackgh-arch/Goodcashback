import { createClient, type SupabaseClient } from '@supabase/supabase-js'

let cachedAdminClient: SupabaseClient | null = null

function getSupabaseAdminClient() {
  if (cachedAdminClient) return cachedAdminClient

  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY

  if (!supabaseUrl || !serviceRoleKey) {
    throw new Error('Supabase admin client is not configured on the server.')
  }

  cachedAdminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
    },
  })

  return cachedAdminClient
}

export const supabaseAdmin = new Proxy({} as SupabaseClient, {
  get(_target, prop) {
    const client = getSupabaseAdminClient() as any
    const value = client[prop as keyof SupabaseClient]
    return typeof value === 'function' ? value.bind(client) : value
  },
})
