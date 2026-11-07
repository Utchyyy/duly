import { Outlet, createFileRoute } from '@tanstack/react-router'
import { Gate } from '#/components/Gate'
import { ConsoleShell, Empty } from '#/components/Shells'
import { useVendor } from '#/lib/vendor'

export const Route = createFileRoute('/pro')({
  head: () => ({ meta: [{ title: 'Duly Pro' }] }),
  component: ProLayout,
})

const nav = [
  { label: 'Today', to: '/pro', exact: true },
  { label: 'Quote requests', to: '/pro/quotes' },
  { label: 'Jobs and crew', to: '/pro/jobs' },
  { label: 'Shifts', to: '/pro/shifts' },
  { label: 'Profile and rates', to: '/pro/profile' },
  { label: 'Verification', to: '/pro/verification' },
  { label: 'Payouts', to: '/pro/payouts' },
  { label: 'Team', to: '/pro/team' },
]

function ProLayout() {
  return (
    <ConsoleShell suffix="Pro" nav={nav} roles={['vendor_admin', 'dispatcher']}>
      <Gate roles={['vendor_admin', 'dispatcher']} allowSignUp={false} signInHeading="Duly Pro">
        <VendorOnly />
      </Gate>
    </ConsoleShell>
  )
}

function VendorOnly() {
  const vendor = useVendor()
  if (!vendor) return <Empty title="You're not attached to a vendor yet">Ask a Duly admin to add you to your company.</Empty>
  return (
    <div className="max-w-5xl">
      <Outlet />
    </div>
  )
}
