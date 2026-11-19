import { Outlet, createFileRoute } from '@tanstack/react-router'
import { Gate } from '#/components/Gate'
import { ConsoleShell, Empty } from '#/components/Shells'
import { ENTERPRISE_NAV } from '#/lib/portal'
import { useEnterprise } from '#/lib/useEnterprise'

export const Route = createFileRoute('/enterprise')({
  head: () => ({ meta: [{ title: 'Duly Enterprise' }] }),
  component: EnterpriseLayout,
})

function EnterpriseLayout() {
  return (
    <ConsoleShell suffix="Enterprise" nav={ENTERPRISE_NAV} roles={['owner', 'approver', 'viewer']}>
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
