import { Outlet, createFileRoute } from '@tanstack/react-router'
import { Gate } from '#/components/Gate'
import { ConsoleShell } from '#/components/Shells'
import { useFeatures } from '#/lib/useFeatures'

export const Route = createFileRoute('/admin')({
  head: () => ({ meta: [{ title: 'Duly Admin' }] }),
  component: AdminLayout,
})

const nav = [
  { label: 'Overview', to: '/admin', exact: true },
  { label: 'Verification', to: '/admin/verification' },
  { label: 'Case files', to: '/admin/cases' },
  { label: 'Operations', to: '/admin/operations' },
  { label: 'Issues', to: '/admin/issues' },
  { label: 'Payments ledger', to: '/admin/payments' },
  { label: 'Workers and DBS', to: '/admin/workers' },
  { label: 'Enterprises', to: '/admin/enterprises' },
  { label: 'Organisations and people', to: '/admin/people' },
  { label: 'Markets and policies', to: '/admin/policies' },
  { label: 'Feature switches', to: '/admin/features' },
]

function AdminLayout() {
  const { features } = useFeatures()
  // The shift exchange screens are hidden while that switch is off.
  const visible = nav.filter((n) => features.shifts || n.to !== '/admin/workers')
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
