import { Outlet, createFileRoute } from '@tanstack/react-router'
import { CrewDevice, CrewStatus, useCrewServiceWorker } from '#/components/CrewDevice'
import { Gate } from '#/components/Gate'
import { AppShell } from '#/components/Shells'

export const Route = createFileRoute('/crew')({
  head: () => ({
    meta: [
      { title: 'Duly Crew' },
      { name: 'apple-mobile-web-app-capable', content: 'yes' },
      { name: 'mobile-web-app-capable', content: 'yes' },
      { name: 'apple-mobile-web-app-title', content: 'Crew' },
      { name: 'apple-mobile-web-app-status-bar-style', content: 'default' },
    ],
    links: [
      { rel: 'manifest', href: '/crew.webmanifest' },
      { rel: 'apple-touch-icon', href: '/icons/apple-touch-icon.png' },
    ],
  }),
  component: CrewLayout,
})

function CrewLayout() {
  useCrewServiceWorker()
  return (
    <AppShell suffix="Crew">
      <Gate allowSignUp signInHeading="Duly Crew">
        <CrewDevice>
          <CrewStatus />
          <Outlet />
        </CrewDevice>
      </Gate>
    </AppShell>
  )
}
