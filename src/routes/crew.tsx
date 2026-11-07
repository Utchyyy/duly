import { Outlet, createFileRoute } from '@tanstack/react-router'
import { Gate } from '#/components/Gate'
import { AppShell } from '#/components/Shells'

export const Route = createFileRoute('/crew')({
  head: () => ({
    meta: [{ title: 'Duly Crew' }, { name: 'apple-mobile-web-app-capable', content: 'yes' }],
    links: [{ rel: 'manifest', href: '/crew.webmanifest' }],
  }),
  component: CrewLayout,
})

function CrewLayout() {
  return (
    <AppShell suffix="Crew">
      <Gate allowSignUp signInHeading="Duly Crew">
        <Outlet />
      </Gate>
    </AppShell>
  )
}
