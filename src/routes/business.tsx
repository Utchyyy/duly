import { createFileRoute } from '@tanstack/react-router'
import { BuyerHome } from '#/components/BuyerHome'
import { Gate } from '#/components/Gate'
import { AppShell } from '#/components/Shells'

export const Route = createFileRoute('/business')({
  head: () => ({ meta: [{ title: 'Duly for Business' }] }),
  component: BusinessPage,
})

function BusinessPage() {
  return (
    <AppShell suffix="for Business" wide>
      <Gate allowSignUp signInHeading="Duly for Business">
        <BuyerHome mode="business" />
      </Gate>
    </AppShell>
  )
}
