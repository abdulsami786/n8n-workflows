# n8n-workflows

LeadOps: admissions lead capture for n8n 2.41. Meta Lead Ads and website inquiries go to the CRM (Zoho Bigin), the right staff member is notified on Telegram, and reminders and escalations go out until someone responds.

| # | Workflow | Starts | What it does |
|---|---|---|---|
| 01 | Meta Lead Ads intake | Webhook `/webhook/leadops/meta` | Checks Meta's signature, saves the lead, hands it to 03 |
| 02 | Website form intake | Webhook `/webhook/leadops/web-form` | Blocks spam, validates, saves, hands it to 03 |
| 03 | Lead processor | Called by 01, 02, 09 | Cleans the data, merges repeat families, picks the agent, calls 04 and 05 |
| 04 | CRM sync (Zoho Bigin) | Called by 03 | Creates the contact once, adds a note for every inquiry |
| 05 | Notify agent | Called by 03, 06 | Telegram/email with "Open and claim" and WhatsApp buttons |
| 06 | SLA watchdog | Every minute | Reminders, then escalation to the manager |
| 07 | Lead page | Webhook `/webhook/leadops/lead` | Lead details, Claim / Contacted buttons |
| 08 | Dashboard | Webhook `/webhook/leadops/dashboard` (login) | Volume, response times, channels, campaigns |
| 09 | Retry sweeper | Every 2 minutes | Retries failed leads with backoff, gives up after 6 tries |
| 10 | Alerts | On any error | Tells the operator, at most once per 15 minutes per problem |
| 11 | Morning digest | 07:30 daily | Yesterday's numbers to the manager |

`mocks/` is for local testing only: **90** stands in for Telegram, Meta Graph and Zoho; **91** sends demo leads through 01 and 02. Do not import them in production.

## Import

```bash
n8n import:workflow --separate --input=workflows
```

The workflows read their settings from environment variables (`.env`, never committed) and need the LeadOps Postgres schema and the `LeadOps DB` credential.
