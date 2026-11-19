// The Enterprise's compliance view of its vendors. The state of each required claim is worked out in SQL
// (`enterprise_vendor_compliance`); this only groups the rows by vendor and counts what needs attention, in the order given.
export type ComplianceRow = {
  vendor_org_id: string
  vendor_name: string
  roster_status: string
  kind: string
  state: string
  claim_id: string | null
  reference: string | null
  valid_until: string | null
  duly_status: string | null
  reviewed_at: string | null
  note: string | null
}

export type VendorCompliance = {
  vendor_org_id: string
  vendor_name: string
  roster_status: string
  rows: ComplianceRow[]
  accepted: number
  needsReview: number
  needsVendor: number
  complete: boolean
}

/** Company claims an Enterprise may require. DBS and right to work are checked per person. */
export const REQUIRABLE_KINDS = ['companies_house', 'public_liability_insurance', 'iso_9001', 'chas', 'safecontractor', 'other'] as const

export const KIND_TEXT: Record<string, string> = {
  companies_house: 'Companies House registration',
  public_liability_insurance: 'Public liability insurance',
  iso_9001: 'ISO 9001',
  chas: 'CHAS',
  safecontractor: 'SafeContractor',
  other: 'Other',
}

export const STATE_TEXT: Record<string, string> = {
  accepted: 'Accepted',
  awaiting: 'Waiting for your review',
  rejected: 'Rejected',
  expired: 'Expired: renewal needed',
  not_sent: 'Not sent yet',
}

/** Group rows by vendor, keeping the order given. `needsReview` is claims waiting on the Enterprise; `needsVendor` is what only the vendor can fix. */
export function groupByVendor(rows: ComplianceRow[]): VendorCompliance[] {
  const out: VendorCompliance[] = []
  for (const r of rows) {
    let v = out.find((x) => x.vendor_org_id === r.vendor_org_id)
    if (!v) {
      v = { vendor_org_id: r.vendor_org_id, vendor_name: r.vendor_name, roster_status: r.roster_status, rows: [], accepted: 0, needsReview: 0, needsVendor: 0, complete: false }
      out.push(v)
    }
    v.rows.push(r)
    if (r.state === 'accepted') v.accepted++
    else if (r.state === 'awaiting') v.needsReview++
    else v.needsVendor++
  }
  for (const v of out) v.complete = v.rows.length > 0 && v.accepted === v.rows.length
  return out
}

export function claimsToReview(rows: ComplianceRow[]): number {
  return rows.filter((r) => r.state === 'awaiting').length
}
