# Duly: Data Protection Impact Assessment (draft)

**Status: DRAFT for review by Duly's data protection lead and legal counsel. No one has signed it off.**
Written on 19 November 2026 from how the product is actually built. It is not legal advice. Anything marked **⚠** is an assumption or a fact I could not check from the code and needs a person to confirm it. Review again before the first pilot and whenever the processing changes in a way that matters (a new kind of data, a new processor, switching the marketplace or the labour exchange back on).

## 1. Why a DPIA

Duly records, for each cleaning visit, who attended, when, where and with what evidence, and shows that record to the organisation that buys the cleaning. Several features meet the ICO's "likely high risk" triggers, so a DPIA is needed rather than merely prudent:

- **Systematic monitoring of workers.** Cleaners' phones give their location when they check in, take a photo or finish a visit.
- **Workers are in a position of weaker bargaining power** against their employer and the client the employer works for.
- **Criminal-offence data.** The labour layer records DBS applications and outcomes.
- **Innovative technology.** An optional AI feature drafts a cleaning brief from text or a document a buyer pastes.
- **Sensitive reports.** Safeguarding concerns can be raised about a visit.

Duly is at pilot scale, so the processing is not yet "large scale", but it is designed to be.

## 2. Description of the processing

### 2.1 What Duly does

An **Enterprise** (a buyer such as a soft-FM provider or multi-site organisation) governs its cleaning **Vendors**. Each Vendor runs the operations that deliver cleans to the Enterprise's sites. Every clean becomes one record the Enterprise, and the Client at the site, can see. Invoicing is outside Duly for Enterprises.

### 2.2 Who the data is about

| People | What Duly holds about them |
| --- | --- |
| Enterprise staff and Client site users | Name or email, role, which sites they can see, what they decided (accepted a claim, judged a visit, raised a problem) |
| Vendor staff (admins, dispatchers) | Email, name, role, what they changed |
| Cleaners (operatives) | Name, phone, email, which visits they are on, check-in and check-out times and **location at those moments**, ticks on the checklist, photos they took and **where** |
| Workers in the labour pool (switched off for the launch) | Name, phone, home town, availability, DBS status, self-rated screening scores |
| People named in complaints, or seen in photos | Whatever a complaint or photo happens to contain |
| People about whom a safeguarding concern is raised | The description the reporter typed |
| Anyone whose details are pasted into the AI drafting feature | Whatever was pasted |

### 2.3 Data map

| Data | Where (tables, storage) | Who can see it | Why it is held | Proposed retention (see the schedule) |
| --- | --- | --- | --- | --- |
| Login identity (email, name, phone) | `auth.users`, `profiles` | The person; their organisation's staff where needed; Duly | Run the account, send notifications | While the account lasts; erasure on request ⚠ (process not built) |
| Roles and access | `memberships`, `site_access` | Organisation admins; Duly | Control who sees what | While the relationship lasts |
| Check-in and check-out events with location | `job_events` | Parties to the job; the screens shown to Enterprises and Clients do not name the cleaner | Prove a visit was attended on site | Coordinates cleared after 13 months; time and on-site result kept |
| Photos with location | `evidence` rows; files in the private `evidence` bucket | Parties to the job | The record of the work | Coordinates cleared after 13 months; files kept as long as an Enterprise may need them (proposed 24 months) ⚠ file removal not built |
| Checklist ticks and verdicts | `plan_results`, `area_results` | Parties to the job | Show what was done and judged | With the visit record |
| Complaints | `issues` | Parties to the job; safeguarding: only the reporter and Duly | Resolve problems, evidence disputes | Six years (contract claims) |
| Company claims (insurance, ISO, CHAS) and their documents | `verification_claims`, private `claim-evidence` bucket | The vendor; Enterprises that list it (not DBS or right to work); Duly | Let an Enterprise check its vendors | While valid, then the claims period |
| Personal claims (DBS, right to work) | `verification_claims` (with a person's id) | The person; their employer; Duly | Show checks were made | Lapsed ones deleted 12 months after |
| DBS applications | `dbs_applications` | The worker; their vendor; Duly | Track clearance | Form, notes and references cleared 12 months after the outcome |
| Notifications | `notifications` | The person it is for | Tell people something needs them | 12 months; read ones 90 days |
| AI drafting source text | `approval_queue.source` | The buyer's owners and approvers | Review the draft | Cleared 6 months after the draft is decided |
| Audit trail | `audit_log` | Duly only | Evidence for disputes | Six years |
| Staff pay (labour pool only) | `shifts.hourly_pay` | Vendors and Duly only, never Enterprises or Clients | Run shifts | With the shift record |

### 2.4 Where the data goes (processors and sub-processors)

| Who | What for | What they receive | Notes |
| --- | --- | --- | --- |
| **Supabase** | Database, sign-in, file storage | Everything above | Project region **eu-west-1 (Ireland)**. Backups may hold deleted data for the backup window ⚠ confirm the window |
| **Vercel** | Hosts the web app | Requests to the app, including who is signed in | ⚠ Confirm the deployment region and its data-processing terms |
| **Resend** (email) | Sends notification emails | Recipient email address and the notification text, which by design carries no pay, amounts, street addresses, access notes or safeguarding detail | ⚠ Likely a US processor: needs a transfer mechanism. Not live until the production keys are set |
| **Anthropic** (optional AI) | Drafts a brief from pasted text or a document | The pasted text or the text of the document, only when a buyer chooses this | ⚠ Likely a US processor. Confirm its retention and training terms for the API. The server holds the key; nothing is sent unless a person chooses to draft |
| **postcodes.io** | Looks up a site's town and coordinates from its postcode | The postcode only | Called from the browser; no person is identified |
| **GitHub** | Holds the source code | No personal data | Code only |

### 2.5 How the system limits what it does

- Row-level security on every table; no signed-out access; signed-out visitors see marketing only.
- Access rules sit in the database, not the app, so a screen cannot widen them.
- Location is read **once**, when the cleaner checks in, takes a photo or finishes a visit. The code has no background or continuous tracking.
- The screens for Enterprises and Clients show **which vendor, which site and what happened**. They do not show crew names, pay or price.
- Safeguarding reports are visible only to the person who raised them and Duly, and are never counted or shown in reports.
- Notifications are made in the database, never carry the sensitive fields above, and can never block the action they report.
- Scoring and ranking are deterministic SQL on measures of visits; there is no AI ranking or pricing, and AI output is only ever a draft a person must approve.
- The audit trail is append-only; it now omits photo coordinates, the reference and notes of personal claims, and the text of safeguarding reports.
- A frozen monthly report cannot be altered once taken.

## 3. Roles and lawful basis (proposed ⚠ counsel to decide)

**Roles.** The split below is my proposal and is the single most important thing for counsel to settle, because it decides who answers to a cleaner who asks for their data.

- **Duly is a processor** for the delivery record it holds on behalf of an Enterprise and its Vendors.
- **Duly is a controller** for account and security data, the audit trail, and its own business records.
- **A Vendor is a controller** of its own staff's data as their employer.
- **An Enterprise** decides why it receives the delivery record, so is a controller of what it receives and how it uses it.
- ⚠ Whether Enterprise and Vendor are **joint controllers** of visit data about cleaners needs a decision and an arrangement between them.

**Lawful basis (proposed).** Contract for accounts and the service; legitimate interests for the verified delivery record and dispute evidence, supported by a short legitimate-interests assessment (needed before the pilot); legal obligation where a check is required by law (right to work is the employer's duty and Duly stores the claim, not the documents).

**Criminal-offence data.** DBS outcomes are Article 10 data. Duly keeps the application form and certificate references only until the outcome has been acted on, then clears them (proposed 12 months), and keeps the outcome. ⚠ Counsel to confirm the Schedule 1 condition and the appropriate policy document.

## 4. Necessity and proportionality

- **Purpose limitation.** Location is used to show a visit was on site, not to follow a person. After the dispute window only the on-site result remains.
- **Minimisation.** Enterprises do not see crew names; safeguarding text is not copied into the audit trail; AI source text is cleared after review; personal claim documents cannot be attached to claims (only company claims take documents).
- **Storage limitation.** A retention schedule with periods held in a database table, editable by Duly staff, applied by a daily scan, and shown in Admin → Data retention. Every rule starts off and must be switched on by a person. See `retention-schedule.md`.
- **Accuracy.** Visit records are written by the system from what the crew did. ⚠ There is no screen for a person to correct their own name or phone; Duly staff do it on request.
- **Transparency.** ⚠ Privacy notices for Enterprises, Vendors, cleaners and Clients are not written yet.
- **Rights.** Access, correction, erasure and objection are currently handled by hand by Duly staff. ⚠ There is no self-service export or erasure tool. Erasure of a person leaves pseudonymous ids in the audit trail for up to six years, which counsel should accept as necessary for establishing or defending legal claims.
- **Automated decisions.** None about individuals in the launch scope. The labour layer's screening score (WIIx) is switched off; **it must be assessed again (Article 22) before it is switched on.**

## 5. Risk register

Likelihood and severity: L(ow), M(edium), H(igh). Residual risk is what remains with the existing controls; **further action** is what I recommend before the pilot.

| # | Risk | L | S | Existing controls | Residual | Further action |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Cleaners' location is used for more than proving attendance, or kept too long | M | H | Single reading at check-in/photo/finish; crew names not shown to Enterprises; coordinates cleared after 13 months (rule, switched off) | Medium | Switch the rule on after sign-off; cleaner-facing notice saying exactly when location is read |
| 2 | Photos capture people or sensitive areas (hospital wards, changing rooms) | M | H | Private bucket; only job parties can open; links to a photo expire after an hour | **High until fixed** | Crew guidance (no people in frame); build the storage job so old photos can be removed; agree a photo period with each Enterprise |
| 3 | A safeguarding report is exposed | L | H | Visible only to the reporter and Duly; excluded from reports; text no longer copied into the audit trail | Low | Confirm Duly's own handling procedure |
| 4 | DBS or other criminal-offence data exposed or over-kept | L | H | Outcome-only elsewhere; form data cleared after 12 months (rule, off); personal claims audited without references | Medium | Appropriate policy document; switch the rules on |
| 5 | AI drafting sends third-party personal data to a processor | M | M | Optional; a person chooses each time; key is server-only; output is a draft a person approves; source cleared after 6 months (rule, off) | Medium | Confirm the processor's terms; a one-line notice at the point of pasting |
| 6 | Email notifications reveal too much, or go to the wrong person | L | M | Text excludes pay, amounts, addresses, access notes and safeguarding detail; rejection reasons are not repeated | Low | Production email provider's terms and transfer mechanism |
| 7 | Staff pay seen by the wrong people | L | M | Pay is visible only in Pro and Admin | Low | None beyond the existing tests |
| 8 | One Enterprise or vendor sees another's data | L | H | Row-level security and database tests of isolation for every Enterprise feature | Low | Keep the isolation tests in every new feature |
| 9 | The immutable audit trail conflicts with erasure and storage limitation | M | M | Sensitive columns no longer copied; rows older than six years can be purged by the retention scan only | Medium | Counsel to accept the six-year period; switch the rule on after sign-off |
| 10 | Transfers outside the UK (Resend, Anthropic, possibly Vercel) | M | M | Database in Ireland; only sent when email or AI is used | Medium | International data transfer agreements or the UK addendum for each ⚠ |
| 11 | Requests from people to see, correct or erase their data cannot be met quickly | M | M | Manual process by Duly staff | Medium | Build an export and an erasure procedure; name a contact |
| 12 | Unauthorised access to an account | L | H | One-time email codes; vendor staff and admins are invite-only; roles come from memberships | Low | Consider extra checks for Duly admin accounts |
| 13 | Deleted data lingers in backups | M | L | Supabase backup window ⚠ | Low | Document the window in the retention schedule |
| 14 | Switching the labour exchange back on brings worker scoring and screening | L | H | Switched off by a feature switch | Low now | A separate assessment before it is switched on |

## 6. Consultation

Not done yet. Before the pilot: Duly's data protection lead and counsel; the anchor Enterprise's data protection team; a sample of Vendors and, through them, cleaners; and, if the Enterprise has them, worker representatives.

## 7. Outcome and sign-off

| | Name | Date |
| --- | --- | --- |
| Prepared by | (draft written with Claude from the codebase) | 19 Nov 2026 |
| Data protection lead's advice | | |
| Residual risk accepted by | | |
| Next review due | before the first pilot | |

## Appendix A: questions for counsel and the data protection lead

1. Roles: who is controller of visit data about cleaners: Vendor, Enterprise, or both jointly?
2. Is legitimate interests the right basis for the verified delivery record, and what does the assessment need to say about cleaners' location?
3. Which Schedule 1 condition and policy document apply to DBS outcomes?
4. Is a six-year audit-trail period acceptable, and is keeping pseudonymous ids after an erasure request defensible?
5. Which transfer mechanism covers Resend and Anthropic, and what are Vercel's region and terms?
6. What notices are needed, to whom, and in what words?

## Appendix B: work still to do (from this assessment)

- Remove old photos and documents from storage (needs a server job; SQL cannot delete storage files).
- Self-service export and an erasure procedure for a person.
- Privacy notices and the cleaner-facing location notice; crew photo guidance.
- Data processing agreements with Enterprises and Vendors, and processor agreements with each sub-processor.
- Switch the retention rules on, one at a time, after review.
