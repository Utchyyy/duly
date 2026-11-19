import { Outlet, createFileRoute } from '@tanstack/react-router'
import { Gate } from '#/components/Gate'
import { AppShell } from '#/components/Shells'

export const Route = createFileRoute('/client')({
  head: () => ({ meta: [{ title: 'Your sites · Duly' }] }),
  component: ClientLayout,
})

// A Client site user has no organisation: they sign in (anyone can create an account) and see only the sites an Enterprise gave them.
function ClientLayout() {
  return (
    <AppShell suffix="Sites" wide>
      <Gate allowSignUp signInHeading="Sign in to see your sites">
        <Outlet />
      </Gate>
    </AppShell>
  )
}
