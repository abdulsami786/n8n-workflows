# Walkthrough video script (6 to 7 minutes)

Record in a clean browser at 1440 px width with Telegram Desktop open. Run `./setup.sh --demo` first so the dashboard has history.

1. **The problem (30 s).** "320 inquiries a month from three channels that don't talk to each other. Leads get lost, nobody knows response times, and there's no attribution. Here's the system that fixes Phase 1."
2. **Architecture (45 s).** Show the README diagram. Stress three ideas:
   - The inbox comes first, so nothing is lost even if the CRM is down.
   - Every step is idempotent, so retries never duplicate.
   - Everything is measurable.
3. **Live Meta lead (60 s).**
   - Run `tests/send_meta_test_lead.sh "ليلى العامري" "٠٥٠١٢٣٤٥٦٧" ar`. Note the Arabic-Indic digits.
   - Show the Telegram message arriving (Arabic detected, campaign attached).
   - Open n8n, execution of workflow 01, then 03.
4. **CRM (30 s).** Show the contact in Bigin: mobile normalised to +971 50 123 4567 and a note with campaign, ad set and answers.
5. **Claim (45 s).**
   - Tap "Open and claim" on a phone and show the lead page.
   - Tap WhatsApp: the greeting is pre-written in Arabic.
   - Tap Claim: "Response time 1 min".
6. **Dedupe (30 s).** Run `tests/send_web_lead.sh` with the same phone twice. The second one is merged, there's no second alert, and the CRM note says "Repeat inquiry".
7. **Reminders and escalation (30 s).** Leave a lead unclaimed and show the reminder at 5 min and the manager escalation after the 10-minute promise. Speed this up by temporarily setting a rule to 1 minute.
8. **Failure handling (45 s).**
   - Break the Telegram token and send a lead. Show the alert and the retry scheduled in the database.
   - Fix the token and show the sweeper delivering it within 2 minutes.
9. **Dashboard (60 s).** Walk through:
   - the headline sentence
   - the dot plot (every inquiry, staffed hours versus after hours)
   - the live queue
   - the weekly trend
   - the heatmap ("40% arrive after hours, mostly 8 to 11 pm", which is a staffing insight)
   - the campaign table ("which campaign actually gets answered fast")
10. **Close (20 s).** Run `tests/acceptance.sh` live: 7 of 7 pass. "Each weekly delivery has a check like this."
