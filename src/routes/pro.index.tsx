import { Link, createFileRoute } from '@tanstack/react-router'
import { Stat } from '#/components/Shells'
import { Badge, ErrorNote, Section, Table } from '#/components/ui'
import { must, useLoad, when } from '#/lib/format'
import { supabase } from '#/lib/supabase'
import { useVendor } from '#/lib/vendor'

export const Route = createFileRoute('/pro/')({ component: ProToday })

type TownRow = { town: string; open_shifts: number; workers: number; balance: number; status: string }

function ProToday() {
  const vendor = useVendor()!
  const { data, error } = useLoad(async () => {
    const db = supabase()
    const start = new Date()
    start.setHours(0, 0, 0, 0)
    const end = new Date(start)
    end.setDate(end.getDate() + 1)
    const [today, quotes, open, profile, towns] = await Promise.all([
      db
        .from('jobs')
        .select('id, status, scheduled_start, site:sites(name, town)')
        .eq('vendor_org_id', vendor.id)
        .gte('scheduled_start', start.toISOString())
        .lt('scheduled_start', end.toISOString())
        .order('scheduled_start'),
      db.from('quotes').select('id', { count: 'exact', head: true }).eq('vendor_org_id', vendor.id).eq('status', 'invited'),
      db.from('shifts').select('id', { count: 'exact', head: true }).eq('vendor_org_id', vendor.id).eq('status', 'open'),
      db.from('vendor_profiles').select('hourly_rate, base_lat').eq('org_id', vendor.id).maybeSingle(),
      db.rpc('demand_by_town'),
    ])
    const org = must(await db.from('organisations').select('verification_tier').eq('id', vendor.id).single())
    return {
      today: must(today),
      quotes: quotes.count ?? 0,
      open: open.count ?? 0,
      profile: profile.data,
      tier: org.verification_tier,
      towns: (towns.data ?? []) as TownRow[],
    }
  }, [vendor.id])

  const missing: string[] = []
  if (data && !data.profile?.hourly_rate) missing.push('set your hourly rate')
  if (data && !data.profile?.base_lat) missing.push('set your base postcode')
  if (data && data.tier < 1) missing.push('get verified')

  return (
    <div className="space-y-8">
      <div>
        <p className="text-sm font-medium text-primary">{vendor.name}</p>
        <h1 className="mt-1 text-3xl">Today</h1>
      </div>
      <ErrorNote message={error} />
      {missing.length > 0 && (
        <div className="card border-alert/30 bg-alert-bg p-4 text-sm text-alert">
          Clients can't find you yet. To appear in search, {missing.join(', ')}.{' '}
          <Link to="/pro/profile" className="font-semibold underline">
            Profile and rates
          </Link>{' '}
          ·{' '}
          <Link to="/pro/verification" className="font-semibold underline">
            Verification
          </Link>
        </div>
      )}
      <div className="grid gap-4 sm:grid-cols-3">
        <Stat label="Jobs today" value={data?.today.length ?? '–'} />
        <Stat label="Quote requests waiting" value={data?.quotes ?? '–'} />
        <Stat label="Open shifts" value={data?.open ?? '–'} />
      </div>
      {data && data.today.length > 0 && (
        <Section title="Today's jobs">
          <Table head={['Time', 'Site', 'Status', '']}>
            {data.today.map((j) => (
              <tr key={j.id}>
                <td>{when(j.scheduled_start)}</td>
                <td>
                  {j.site?.name}, {j.site?.town}
                </td>
                <td>
                  <Badge value={j.status} />
                </td>
                <td>
                  <Link to="/crew/$jobId" params={{ jobId: j.id }} className="link-action font-semibold text-primary">
                    Job sheet
                  </Link>
                </td>
              </tr>
            ))}
          </Table>
        </Section>
      )}
      <Section title="Labour by town">
        <Table head={['Town', 'Open shifts', 'Workers', 'Status']}>
          {(data?.towns ?? []).map((t) => (
            <tr key={t.town}>
              <td className="font-medium">{t.town}</td>
              <td>{t.open_shifts}</td>
              <td>{t.workers}</td>
              <td>
                <Badge value={t.status === 'Deficit' ? 'open' : 'met'}>{t.status}</Badge>
              </td>
            </tr>
          ))}
        </Table>
      </Section>
    </div>
  )
}
