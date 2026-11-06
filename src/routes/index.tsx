import { Link, createFileRoute } from '@tanstack/react-router'
import { BuyerHome } from '#/components/BuyerHome'
import { AppShell } from '#/components/Shells'
import { SignIn } from '#/components/SignIn'
import { useAuth } from '#/lib/auth'

export const Route = createFileRoute('/')({ component: BuyerPage })

function BuyerPage() {
  const { ready, session } = useAuth()

  return (
    <AppShell>
      {ready && session ? (
        <BuyerHome mode="home" />
      ) : (
        <div className="space-y-8">
          <section className="pt-4">
            <h1 className="text-4xl leading-tight">A cleaner you can check, a clean you can prove.</h1>
            <p className="mt-3 text-lg text-ink-2">
              Find verified local cleaners, agree exactly what gets done, and only release payment when the evidence
              shows it was.
            </p>
          </section>
          <SignIn allowSignUp heading="Get started" />
          <p className="text-center text-sm text-ink-2">
            Running a business?{' '}
            <Link to="/business" className="font-semibold text-primary">
              Duly for Business
            </Link>
          </p>
        </div>
      )}
    </AppShell>
  )
}
