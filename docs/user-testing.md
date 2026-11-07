# Duly user testing: script for real testers

Use this to watch real people use every part of Duly: a homeowner, a business owner, a vendor, a cleaner on a phone, and Duly's own admin. It is task-based on purpose. Tell people what they want to get done, not which buttons to press, so you see where the wording and layout let them down.

## 1. Before the session (organiser)

Never test on the live project. Live is the real database, and the audit log can never be wiped.

1. **A throwaway database.** Create a Supabase branch of the Duly project (it copies the schema and sample vendors, no real data).
2. **A site testers can open.** Deploy the app with the branch's URL and publishable key as `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE`, for that deploy only. A plain Vercel preview of this repo points at live, so do not hand that out.
3. **Accounts.** Make one set per tester so they do not trip over each other: a homeowner, a business owner, a vendor admin, a crew member and one admin, all signed in with email and a shared test password you tell them in person. The vendor and crew belong to the sample vendor "Clean-Fit", raised to verification level 2 by the admin as the first step.
4. **Tell testers:** this is a practice copy, nothing is real, do not enter real addresses, names or phone numbers, and use the postcode `CO1 1AA`.
5. **Phones.** The crew task needs a real phone with location switched on, in a place near the test site. If testers are not in Colchester, expect photos and check-in to be flagged "off site". That is the system working, and it is useful to see how it reads.
6. **After:** delete the branch and the deploy.

Allow about 60 minutes per person for all roles, or split roles across people (one person per role is fine; the tasks hand over to each other in the order below).

## 2. Ground rules for the facilitator

- Ask them to think aloud: "say what you are looking at and what you expect".
- Do not help or explain. If they are stuck for two minutes, note it and nudge: "what would you try next?". Only unblock them after five minutes, and write down where.
- Note exact words they use for things (for example "job", "brief", "escrow", "verdict").
- Do not defend the product. "Thanks, that is useful" is the only answer.

## 3. The tasks

Do them in order. Each hands work to the next one.

### Task 1: Homeowner
*"You want your home cleaned every other week. Get something ready so cleaners can tell you what it would cost."*
- Start from the front page. They create their home, add a brief and describe what they want cleaned.
- Watch for: do they understand "brief", "area", "standards" and "minutes per visit"? Do they notice the lock step? What do they think locking does?
- Done when: a brief exists and they say what will happen next.

### Task 2: Business owner
*"You run a dental practice with a surgery and a reception. You want it cleaned Tuesday evenings. Find a company and get a price."*
- Watch for: do they find "Draft from a document" and understand it only produces a draft? Do they build the areas and choose a type? Do they understand the ranked list and that price does not change the order? Which vendor do they pick, and why?
- They lock the brief and ask Clean-Fit for a quote.
- Done when: Clean-Fit has been asked.

### Task 3: Vendor
*"A client has asked your company for a price. Reply, and once they book, get a cleaner sorted."*
- Watch for: can they find the request? Do they trust that the price is calculated for them? Can they see what they need to see before booking, and notice that the address is hidden until then?
- The business owner then accepts the quote and picks a start time just a few minutes ahead. The vendor assigns the crew member.
- Done when: the job shows a cleaner assigned.

### Task 4: Cleaner, on a phone
*"You are the cleaner. You have just arrived at the surgery. Do the job and tell the client you are finished."*
- Watch for: do they find the job, the access notes and directions? Do they understand "check in"? Do they know what to photograph and tick? What do they do when they are told something is missing before they can finish?
- Optional: switch the phone to aeroplane mode, take a photo, then reconnect. Does the message make sense?
- Done when: the job shows as finished.

### Task 5: Business owner checks the work
*"Your cleaner says they are done. Decide if you are happy and what happens to the money."*
- Run it twice if you can: once happy, once with one standard not met and a problem reported.
- Watch for: do they find "Check the work" on their dashboard? Do they understand what the photos and the "off site" label mean? What do they expect to happen to the money? In the unhappy path, do they understand the job is on hold?
- Done when: the clean is approved, or a problem is reported.

### Task 6: Duly admin
*"A client says the floor was not cleaned. The vendor says it was. Decide what to do and be able to show your reasoning."*
- Watch for: can they find the issue, and the case file? Does the timeline answer "who did what, when, from where"? What is missing that they would want in front of them? Would they trust it as evidence, and would they print it?
- They record an outcome and the bank transfer.
- Done when: the outcome is recorded and they can say why.

## 4. Note sheet (one per person per task)

| | |
|---|---|
| Tester / role | |
| Task finished without help? | yes / with a nudge / no |
| Time taken | |
| Where did they hesitate or go the wrong way? | |
| What did they say, word for word? | |
| Anything they expected that was not there? | |
| Anything they did not understand? | |

Ask after each task, 1 (very hard) to 5 (very easy):
- How easy was that?
- How sure are you that it did what you meant?

## 5. Debrief (end of the session)

- What was the most confusing moment?
- What would you tell a friend this does?
- Would you trust it with real money? What would make you trust it more?
- (Vendor) Does the price feel fair, and do you understand how it was worked out?
- (Cleaner) Is there anything you would not want your employer to see about how you use this?
- (Admin) What is the first thing you would want to add to a case file?
- If you could change one thing, what is it?

## 6. What this cannot test yet

- Drafting with the real AI model (needs the Anthropic key set on that deploy).
- Emails (no sending is set up for the test copy), card payments and push notifications (not built).
- Sample vendors other than Clean-Fit have no staff, so a quote request to them reaches nobody. Tell testers to choose Clean-Fit, or note if they prefer another.

## 7. Afterwards

1. Collect the note sheets the same day while memory is fresh.
2. Mark each finding as a bug (broken), confusing (they misunderstood) or missing (they wanted something). Count how many testers hit each one: anything two or more people hit is the first thing to fix.
3. Delete the branch and the deploy.
