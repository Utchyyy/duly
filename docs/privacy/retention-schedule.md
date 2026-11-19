# Duly: data retention schedule (proposed)

**Status: PROPOSED. These periods are a starting point for Duly's data protection lead and counsel to confirm.** Nothing is deleted or cleared until a person switches a rule on in **Admin → Data retention**. The periods live in the database (`data_retention_rules`) and can be changed there; this document is the reasoning.

## How it is enforced

A daily scan (03:45 UTC) applies every rule that is switched on, in batches of 5,000 so a first run cannot hold a lock for long, and logs what it did. Admin → Data retention shows each rule, what it would act on right now, when it last acted and what it did.

Two kinds of rule: **clear** removes the sensitive fields of a record and keeps the record; **delete** removes the whole record. A **report** rule only counts, and is used where the files must be removed by a job that does not exist yet.

## The schedule

| Data | Period | What happens | Rule | Why |
| --- | --- | --- | --- | --- |
| Notifications | 12 months (read ones: 90 days, already in force) | Deleted | `notifications_old` | They carry no pay, amounts, addresses or safeguarding detail; an old inbox has no use |
| Check-in and check-out locations | 13 months | Coordinates cleared; time, kind of event and whether it was on site kept | `job_event_locations` | The place matters only while attendance could be disputed; a year and a month covers an annual review |
| Photo locations | 13 months | Coordinates cleared; photo, time and on-site result kept | `evidence_locations` | As above |
| AI drafting source text | 6 months after the draft is approved or rejected | Source cleared; the draft and its outcome kept | `ai_draft_sources` | Only needed while a person reviews it; may contain third-party personal data |
| DBS application forms | 12 months after the outcome (cleared, not cleared, withdrawn) | Form data, notes, certificate reference and update-service id cleared; outcome kept | `dbs_application_forms` | Criminal-record-check material is kept no longer than needed |
| Lapsed personal claims (DBS, right to work) | 12 months after rejection, expiry or the end of validity | Deleted | `personal_claims` | No continuing purpose |
| Photos in storage | 24 months (proposal to agree with each Enterprise) | **Counted only.** Files cannot be removed from SQL | `evidence_photos` | The record of the work; an Enterprise may need it for a review or dispute |
| Audit trail | 6 years (the database will not delete anything younger, whatever the rule says) | Deleted | `audit_log` | Evidence for disputes; six years is the contract limitation period in England and Wales |

## Not yet automated

| Data | Proposed period | What is needed |
| --- | --- | --- |
| Photo files, claim documents and brief source documents in storage | Photos 24 months; claim documents while valid then six years; brief sources 6 months | A server job with the service role that removes the files and then the rows that point at them |
| Account data (`auth.users`, `profiles`, memberships) | While the account or relationship lasts, then erase on request | An erasure procedure that handles the audit trail honestly (pseudonymous ids remain for up to six years) |
| Visit records, issues, quotes, contracts, work schedules and frozen monthly packs | Six years after the contract ends | A rule once contracts can be ended and archived |
| Backups | Supabase's backup window | Document the window; deleted data may persist there until it rolls off ⚠ |

## Changes made to the audit trail so this works

The audit trail is append-only and used to copy whole rows, so clearing a column in the source table would have left a permanent copy. From this change it no longer copies photo coordinates, the reference, notes and document path of a personal claim, or the text and resolution of a safeguarding report. Company claims and ordinary issues are audited in full, because they are the evidence in a dispute. The only deletion the audit trail now allows is the retention scan removing a row more than six years old.
