import { Outlet, createFileRoute } from '@tanstack/react-router'
import { Gate } from '#/components/Gate'
import { ConsoleShell } from '#/components/Shells'
import { ADMIN_NAV, visibleNav } from '#/lib/portal'
import { useFeatures } from '#/lib/useFeatures'

export const Route = createFileRoute('/admin')({
  head: () => ({ meta: [{ title: 'Duly Admin' }] }),
  component: AdminLayout,
})

function AdminLayout() {
  const { features } = useFeatures()
  // The shift exchange screens are hidden while that switch is off.
  const visible = visibleNav(ADMIN_NAV, features)
  return (
    <ConsoleShell suffix="Admin" nav={visible} roles={['platform_admin']}>
      <Gate roles={['platform_admin']} allowSignUp={false} signInHeading="Duly Admin">
        <div className="max-w-5xl">
          <Outlet />
        </div>
      </Gate>
    </ConsoleShell>
  )
}
