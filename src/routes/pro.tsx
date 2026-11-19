import { Outlet, createFileRoute } from '@tanstack/react-router'
import { Gate } from '#/components/Gate'
import { ConsoleShell, Empty } from '#/components/Shells'
import { PRO_NAV, visibleNav } from '#/lib/portal'
import { useFeatures } from '#/lib/useFeatures'
import { useVendor } from '#/lib/vendor'

export const Route = createFileRoute('/pro')({
  head: () => ({ meta: [{ title: 'Duly Pro' }] }),
  component: ProLayout,
})

function ProLayout() {
  const { features } = useFeatures()
  // The shift exchange is hidden while that switch is off: vendors use their own staff.
  const visible = visibleNav(PRO_NAV, features)
  return (
    <ConsoleShell suffix="Pro" nav={visible} roles={['vendor_admin', 'dispatcher']}>
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
