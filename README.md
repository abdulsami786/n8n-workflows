# LeadOps for n8n

Admissions lead capture on n8n 2.41. Meta Lead Ads and website inquiries go to the CRM (Zoho Bigin), the right staff member is notified on Telegram, and reminders and escalations go out until someone responds. A dashboard shows volume and response times.

The local setup below runs everything on one Windows PC with **mock** Telegram, Meta and Zoho (workflow 90), so the whole flow works without any accounts.

## Run it on Windows

### 1. Install once

- **PostgreSQL 17**: https://www.postgresql.org/download/windows/ . Remember the password you choose for the `postgres` user.
- **Node.js 22 LTS**: https://nodejs.org , then in a terminal: `npm install -g n8n@2.41.3`
- **Git for Windows**: https://git-scm.com (for cloning and for the tests)

### 2. Set up (once, about 5 minutes)

```powershell
git clone https://github.com/abdulsami786/n8n-workflows.git
cd n8n-workflows
powershell -ExecutionPolicy Bypass -File setup-local.ps1
```

The script creates `.env` with random passwords, asks for the `postgres` password (first time only), creates the database, loads the tables and 95 days of demo data, imports and publishes all workflows, and starts n8n. It ends with `Done`. Running it again is safe.

### 3. Open n8n

Go to http://localhost:5678 and create your n8n account (first time only).

### 4. Try it

- **Send demo leads:** http://localhost:5678/webhook/leadops/demo-leads?count=5 . After about 10 seconds a page shows what happened to each lead, with links to every step in n8n.
- **Dashboard:** http://localhost:5678/webhook/leadops/dashboard . User `admissions`, password is the `DASHBOARD_PASSWORD` line in `.env` (open it with `notepad .env`).

### After every PC restart

n8n does not start by itself. Press **Win + R**, paste this (use your folder), press Enter:

```powershell
powershell -ExecutionPolicy Bypass -File C:\path\to\n8n-workflows\start-n8n.ps1
```

Keep that window open (minimizing is fine) and wait 1 to 3 minutes. **Never start n8n by typing plain `n8n`**: it then runs without the settings in `.env` and every workflow fails.

### Check that everything works

In **Git Bash**, inside the folder:

```bash
bash tests/acceptance.sh
```

Expected result: `7 passed, 0 failed`.

## APIs

| Method | URL | What it is |
|---|---|---|
| GET, POST | `/webhook/leadops/meta` | Meta Lead Ads webhook (GET answers Meta's verification, POST must be signed by Meta) |
| POST | `/webhook/leadops/web-form` | Website form. JSON or form fields: `name`, `phone` and/or `email`, `message`, `utm_*` |
| GET, POST | `/webhook/leadops/lead?t=TOKEN&u=AGENT` | Lead page from the Telegram message. Claim / Contacted are buttons (POST) |
| GET | `/webhook/leadops/dashboard` | Dashboard, basic auth. `?days=7\|30\|90`, `&format=json` for BI tools |
| GET | `/webhook/leadops/demo-leads?count=5` | Demo lead generator (local testing only) |
| | `/webhook/mock-telegram`, `mock-graph`, `mock-zoho`, `mock-bigin` | Mock services (local testing only) |

Send one lead yourself from Git Bash:

```bash
bash tests/send_web_lead.sh "Test Parent" "+971501234567" "parent@example.com"
bash tests/send_meta_test_lead.sh "Test Parent" "0501234567" en
```

## The workflows

| # | Workflow | Starts | What it does |
|---|---|---|---|
| 01 | Meta Lead Ads intake | Meta webhook | Checks Meta's signature, saves the lead, hands it to 03 |
| 02 | Website form intake | Form webhook | Blocks spam, validates, saves, hands it to 03 |
| 03 | Lead processor | Called by 01, 02, 09 | Cleans the data, merges repeat families, picks the agent, calls 04 and 05 |
| 04 | CRM sync (Zoho Bigin) | Called by 03 | Creates the contact once, adds a note for every inquiry |
| 05 | Notify agent | Called by 03, 06 | Telegram/email with "Open and claim" and WhatsApp buttons |
| 06 | SLA watchdog | Every minute | Reminders, then escalation to the manager |
| 07 | Lead page | Lead link | Lead details, Claim / Contacted buttons |
| 08 | Dashboard | Dashboard link | Volume, response times, channels, campaigns |
| 09 | Retry sweeper | Every 2 minutes | Retries failed leads with backoff, gives up after 6 tries |
| 10 | Alerts | On any error | Tells the operator, at most once per 15 minutes per problem |
| 11 | Morning digest | 07:30 daily | Yesterday's numbers to the manager |
| 90 | Mock providers | Mock webhooks | Stands in for Telegram, Meta Graph and Zoho (local only) |
| 91 | Demo lead generator | Demo link or button | Sends demo leads through 01 and 02 (local only) |

Do not press **Execute workflow** in 03, 04, 05 or 10: they only work when another workflow calls them with a lead. To see what happened, open a workflow's **Executions** tab, click a run, then double-click a node.

## Troubleshooting

| You see | Why | Fix |
|---|---|---|
| `{"message":"Error in workflow"}` | n8n was started with plain `n8n` | Close that window, start it with `start-n8n.ps1` |
| `The requested webhook ... is not registered` | n8n is still starting | Wait 1 to 3 minutes. Still there? Run `setup-local.ps1` again |
| `Mismatching encryption keys` | An n8n command was run inside this folder (n8n reads `.env` from the current folder) | Use the two scripts, or run n8n commands from another folder |
| The orange Execute button in 91 spins forever | It is waiting for a test call on the webhook trigger | Click the square to stop, then choose "Run it (button)" in the button's menu |
| Setup says `Connecting as postgres (wrong password?) failed` | Wrong `postgres` password | Use the password chosen when PostgreSQL was installed |

## Going live with real services

Change these lines in `.env`, then close the n8n window and run `start-n8n.ps1` again:

| Service | In `.env` |
|---|---|
| Telegram | `TELEGRAM_BOT_TOKEN` (from @BotFather), delete the `TELEGRAM_API_BASE` line, then put real chat ids in the database: `UPDATE leadops.agents SET telegram_chat_id='123456789' WHERE code='sara';` |
| Meta Lead Ads | `META_APP_SECRET`, `META_PAGE_ACCESS_TOKEN`, delete the `META_GRAPH_BASE` line |
| Zoho Bigin | `ZOHO_CLIENT_ID`, `ZOHO_CLIENT_SECRET`, `ZOHO_REFRESH_TOKEN`, real `ZOHO_ACCOUNTS_URL` and `BIGIN_API_BASE` |

Meta and your website can only reach n8n on a public HTTPS address, not on `localhost`. For a server, follow [docs/SETUP.md](docs/SETUP.md) (Docker: `.env.example` and `./setup.sh`); that path comes from the original project and was not re-tested on this Windows setup. More background: [docs/OVERVIEW.md](docs/OVERVIEW.md), [docs/RUNBOOK.md](docs/RUNBOOK.md).

`.env` holds your passwords. It is created on your PC and never committed (see `.gitignore`).
