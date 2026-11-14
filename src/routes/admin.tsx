import { Outlet, createFileRoute } from '@tanstack/react-router'
import { Gate } from '#/components/Gate'
import { ConsoleShell } from '#/components/Shells'

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
  { label: 'Organisations and people', to: '/admin/people' },
  { label: 'Markets and policies', to: '/admin/policies' },
]

function AdminLayout() {
  return (
    <ConsoleShell suffix="Admin" nav={nav} roles={['platform_admin']}>
      <Gate roles={['platform_admin']} allowSignUp={false} signInHeading="Duly Admin">
        <div className="max-w-5xl">
          <Outlet />
        </div>
      </Gate>
    </ConsoleShell>
  )
}
