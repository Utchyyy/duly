import { Outlet, createFileRoute } from '@tanstack/react-router'
import { Gate } from '#/components/Gate'
import { ConsoleShell, Empty } from '#/components/Shells'
import { useEnterprise } from '#/lib/useEnterprise'

export const Route = createFileRoute('/enterprise')({
  head: () => ({ meta: [{ title: 'Duly Enterprise' }] }),
  component: EnterpriseLayout,
})

const nav = [
  { label: 'Overview', to: '/enterprise', exact: true },
  { label: 'Delivery', to: '/enterprise/delivery' },
  { label: 'Vendors', to: '/enterprise/vendors' },
  { label: 'Sites and clients', to: '/enterprise/sites' },
]

function EnterpriseLayout() {
  return (
    <ConsoleShell suffix="Enterprise" nav={nav} roles={['owner', 'approver', 'viewer']}>
      <Gate roles={['owner', 'approver', 'viewer']} allowSignUp={false} signInHeading="Duly Enterprise">
        <EnterpriseOnly />
      </Gate>
    </ConsoleShell>
  )
}

function EnterpriseOnly() {
  const enterprise = useEnterprise()
  if (!enterprise) return <Empty title="You're not attached to an Enterprise yet">Ask a Duly admin to set up your organisation.</Empty>
  return (
    <div className="max-w-5xl">
      <Outlet />
    </div>
  )
}
