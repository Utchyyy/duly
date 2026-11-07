import { createFileRoute } from '@tanstack/react-router'
import { TeamManager } from '#/components/TeamManager'
import { useVendor } from '#/lib/vendor'

export const Route = createFileRoute('/pro/team')({ component: ProTeam })

function ProTeam() {
  const vendor = useVendor()!
  return (
    <div className="space-y-6">
      <h1 className="text-3xl">Team</h1>
      <TeamManager
        orgId={vendor.id}
        roles={['operative', 'dispatcher', 'vendor_admin']}
        canAdd={vendor.isAdmin}
        hint={`Ask them to open Duly Crew (${typeof window === "undefined" ? "" : window.location.origin}/crew) and sign in once with their email first. Then add them here and assign them to jobs.`}
      />
    </div>
  )
}
