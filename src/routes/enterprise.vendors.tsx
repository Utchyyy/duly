import { createFileRoute } from '@tanstack/react-router'
import { useState } from 'react'
import { Empty } from '#/components/Shells'
import { Badge, ErrorNote, Loading, Section, Table } from '#/components/ui'
import { day, must, useLoad } from '#/lib/format'
import { supabase } from '#/lib/supabase'
import { useEnterprise } from '#/lib/useEnterprise'

export const Route = createFileRoute('/enterprise/vendors')({ component: EnterpriseVendors })

function EnterpriseVendors() {
  const enterprise = useEnterprise()!
  const [busy, setBusy] = useState<string | null>(null)
  const [actionError, setActionError] = useState<string | null>(null)
  const { data, error, reload } = useLoad(
    async () =>
      must(
        await supabase()
          .from('enterprise_vendors')
          .select('vendor_org_id, status, note, created_at, status_changed_at, vendor:organisations!enterprise_vendors_vendor_org_id_fkey(name)')
          .eq('enterprise_org_id', enterprise.id)
          .order('created_at'),
      ),
    [enterprise.id],
  )

  async function setStatus(vendorId: string, status: 'active' | 'suspended') {
    setBusy(vendorId)
    setActionError(null)
    const { error: err } = await supabase().rpc('enterprise_set_vendor_status', { p_enterprise: enterprise.id, p_vendor: vendorId, p_status: status })
    setBusy(null)
    if (err) return setActionError(err.message)
    reload()
  }

  if (error) return <ErrorNote message={error} />
  if (!data) return <Loading />

  return (
    <div className="space-y-8">
      <div>
        <h1 className="text-3xl">Vendors</h1>
        <p className="mt-1 max-w-2xl text-sm text-ink-2">
          Only vendors on this roster can be appointed to your sites. Duly adds a vendor when it is onboarded; you accept it here before you can appoint it. Suspending a vendor stops new appointments and
          new quotes being accepted. Visits already booked carry on.
        </p>
      </div>
      <ErrorNote message={actionError} />
      <Section title="Your roster">
        {data.length === 0 ? (
          <Empty title="No vendors yet">Duly adds your vendors during onboarding.</Empty>
        ) : (
          <Table head={['Vendor', 'Status', 'Note', 'Added', '']}>
            {data.map((r) => (
              <tr key={r.vendor_org_id}>
                <td className="font-semibold">{r.vendor?.name}</td>
                <td>
                  <Badge value={r.status} />
                </td>
                <td className="text-ink-2">{r.note ?? ''}</td>
                <td>{day(r.created_at)}</td>
                <td className="text-right">
                  {enterprise.canManage &&
                    (r.status === 'active' ? (
                      <button className="btn btn-ghost text-sm" disabled={busy === r.vendor_org_id} onClick={() => void setStatus(r.vendor_org_id, 'suspended')}>
                        Suspend
                      </button>
                    ) : (
                      <button className="btn btn-primary text-sm" disabled={busy === r.vendor_org_id} onClick={() => void setStatus(r.vendor_org_id, 'active')}>
                        {r.status === 'invited' ? 'Accept onto roster' : 'Make active again'}
                      </button>
                    ))}
                </td>
              </tr>
            ))}
          </Table>
        )}
      </Section>
    </div>
  )
}
