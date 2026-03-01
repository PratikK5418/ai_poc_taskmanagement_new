# n8n Agentic AI Setup — LSEG Data Operations Hub

> **Your setup**: Raspberry Pi + Docker + Cloudflare Tunnel on your own domain.
> All webhook URLs below use your domain (replace `n8n.yourdomain.com`).

---

## Automation vs Agentic AI — The Key Difference

```
AUTOMATION (what we are NOT doing):
  Webhook → SQL Query 1 → SQL Query 2 → Format → Respond
  ❌ Fixed pipeline. Every request runs the same queries in the same order.
  ❌ No reasoning. No decisions. Just plumbing.

AGENTIC AI (what we ARE doing):
  Webhook → AI Agent (LLM) ←→ Tools (SQL, Embeddings, APIs)
  ✅ LLM DECIDES which tools to call based on the input.
  ✅ LLM REASONS about the data it gets back.
  ✅ LLM CHAINS multiple tool calls if needed.
  ✅ Different inputs → different execution paths → intelligent output.
```

**Example**: User asks chatbot "Who should handle ISIN tasks in Instruments queue?"
- **Automation** would run a hardcoded SQL and return a table.
- **Agentic AI** autonomously: (1) calls "Get Team Availability" → (2) sees who handles Instruments → (3) calls "Get Resolution History" for those analysts → (4) checks leave schedule → (5) **reasons** and recommends the best person with an explanation.

---

## Architecture

```
┌───────────────────┐                    ┌──────────────────────────────────────────┐
│   UI (Browser)    │    HTTPS webhook   │  n8n on Raspberry Pi                     │
│                   │ ─────────────────► │  (Docker, Cloudflare Tunnel)             │
│  • AI Assign btn  │                    │                                          │
│  • Auto-assign    │ ◄───────────────── │  ┌─────────────────────────────────────┐ │
│  • Chatbot        │    JSON response   │  │  AI AGENT NODE (OpenAI GPT-4o)      │ │
│  • Embedding gen  │                    │  │                                     │ │
└───────────────────┘                    │  │  The LLM autonomously invokes:      │ │
                                         │  │                                     │ │
                                         │  │  ┌─── Tool: Find Similar Tasks      │ │
                                         │  │  ├─── Tool: Get Resolution History  │ │
                                         │  │  ├─── Tool: Check Leave Schedule    │ │
                                         │  │  ├─── Tool: Get Queue Workload      │ │
                                         │  │  ├─── Tool: Get Team Availability   │ │
                                         │  │  ├─── Tool: Get SLA Breaches        │ │
                                         │  │  └─── Tool: Get Task Statistics     │ │
                                         │  │                                     │ │
                                         │  │  LLM decides WHICH tools to call,   │ │
                                         │  │  in WHAT order, and HOW to combine  │ │
                                         │  │  the results into a response.       │ │
                                         │  └──────────────┬──────────────────────┘ │
                                         │                 │                        │
                                         │                 ▼                        │
                                         │  ┌─────────────────────────────────────┐ │
                                         │  │  Supabase (PostgreSQL + pgvector)   │ │
                                         │  └─────────────────────────────────────┘ │
                                         └──────────────────────────────────────────┘
```

---

## Step 1: n8n on Raspberry Pi with Docker

### 1a. Install Docker (if not already)

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
# Log out and back in, then verify:
docker --version
```

### 1b. Run n8n with Docker Compose

Create `~/n8n/docker-compose.yml`:

```yaml
version: '3.8'
services:
  n8n:
    image: n8nio/n8n:latest
    restart: unless-stopped
    ports:
      - "5678:5678"
    environment:
      - N8N_HOST=n8n.yourdomain.com
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - WEBHOOK_URL=https://n8n.yourdomain.com/
      - N8N_SECURE_COOKIE=true
      - GENERIC_TIMEZONE=Asia/Kolkata
      - N8N_DEFAULT_BINARY_DATA_MODE=filesystem
      # AI Agent settings
      - N8N_AI_ENABLED=true
    volumes:
      - ./n8n_data:/home/node/.n8n
      - ./n8n_files:/files
```

> **IMPORTANT**: Set `WEBHOOK_URL` to your Cloudflare tunnel domain.
> This ensures n8n generates correct webhook URLs like `https://n8n.yourdomain.com/webhook/ai-assign`.

```bash
cd ~/n8n
docker compose up -d
```

### 1c. Cloudflare Tunnel (you already have this)

Your Cloudflare tunnel should route:
```
n8n.yourdomain.com → localhost:5678
```

Verify: Open `https://n8n.yourdomain.com` in your browser → you should see the n8n login page.

### 1d. Verify Webhook Accessibility

After creating any workflow with a webhook, test from your local machine:
```bash
curl -X POST https://n8n.yourdomain.com/webhook-test/ai-assign \
  -H "Content-Type: application/json" \
  -d '{"test": true}'
```

You should get a response (even if it's an error from the workflow — that means the tunnel works).

---

## Step 2: Add Credentials in n8n

Go to `https://n8n.yourdomain.com` → **Settings → Credentials**:

### 2a. OpenAI Credential
- Name: `OpenAI`
- API Key: from https://platform.openai.com/api-keys

### 2b. Postgres Credential (Supabase)
- Name: `Supabase DB`
- Type: **Postgres**
- Host: `db.hsnzhluqydtlxsrymvdr.supabase.co`
- Port: `5432`
- Database: `postgres`
- User: `postgres`
- Password: Your Supabase database password (Project Settings → Database → Connection string)
- SSL: **Enable** (required for Supabase)

Test both credentials to make sure they connect.

---

## Step 3: Import the 3 Workflows

> **Importable JSON files are in the `n8n-workflows/` folder.** Import them directly into n8n.

### How to Import

1. Open n8n → **Workflows** → **+** (top right) → **Import from File**
2. Select the JSON file
3. **Update credentials** — each imported workflow has placeholder credential IDs. Click each node that uses a credential (Postgres tools, OpenAI model) and select your saved credentials from Step 2.
4. **Activate** the workflow (toggle ON in top right)
5. Repeat for all 3 workflows

### Files to Import

| File | Webhook Path | Purpose |
|------|-------------|---------|
| `wf1-ai-task-assignment.json` | `/webhook/ai-assign` | Agentic task assignment |
| `wf2-chatbot-agent.json` | `/webhook/chat` | Agentic chatbot |
| `wf3-embedding-generator.json` | `/webhook/embed-task` | Task embedding generation |

After importing + activating, your webhook URLs will be:
```
https://n8n.yourdomain.com/webhook/ai-assign
https://n8n.yourdomain.com/webhook/chat
https://n8n.yourdomain.com/webhook/embed-task
```

Enter these in the UI → **AI Settings** (gear icon in sidebar).

---

## What Each Workflow Does

### WF1: AI Task Assignment Agent (Agentic)

**Nodes**: Webhook → AI Agent (GPT-4o) → Respond to Webhook
**Tools attached to Agent**: Find Similar Resolved Tasks, Get Analyst Detail, Check Leave Schedule

**Incoming payload** (from lseg-app.js):
```json
{
  "task_id": "task-xxx",
  "mode": "suggest",
  "task_context": {
    "ref": "TSK-100", "queue": "Instruments", "queue_id": "instruments",
    "priority": "High", "field": "ISIN", "rule": "Not Null",
    "domain_id": "equities", "domain": "Equities",
    "sla_deadline": "2025-02-28T10:00:00Z", "outcomes_count": 15
  },
  "eligible_analysts": [
    {
      "analyst_id": "john@lseg.com", "name": "John Smith",
      "active_tasks": 2, "experience_yrs": 5,
      "speciality": ["ISIN", "CFI Code"],
      "queues": ["Instruments", "Quotes"],
      "country": "India",
      "avg_resolution_mins": 35,
      "working_hrs_from": "09:00", "working_hrs_to": "17:00",
      "timezone": "Asia/Kolkata",
      "in_working_hours": true, "working_hrs_label": "09:00 - 17:00",
      "on_leave_today": false, "leave_note": null
    }
  ]
}
```

> **Prerequisites done by frontend**: Filters analysts by same queue + same domain.
> **AI Agent does ALL the heavy lifting**: Scoring, ranking, reasoning, tool calls.

**Scoring dimensions** (6, all done by the AI Agent — NOT the frontend):

| Dimension | Weight | What it measures |
|-----------|--------|-----------------|
| Availability | 20% | On leave today? (25 if yes, 100 if no) |
| Workload | 20% | Fewer active_tasks = higher. Relative to peers. |
| Speciality | 20% | Does speciality match task field? (ISIN, CFI Code, etc.) |
| Working Hours | 15% | Is analyst currently in their working hours? (in_working_hours field) |
| Experience | 13% | More years = higher score |
| SLA Fit | 12% | Urgent deadline? Prefer faster avg_resolution_mins |

**Output format** the AI Agent returns:
```json
[{
  "analyst_id": "john@lseg.com",
  "overall_score": 85,
  "scores": {
    "Availability": 100, "Workload": 80, "Speciality": 90,
    "Working Hours": 100, "Experience": 70, "SLA Fit": 85
  },
  "reasoning": "John resolved 3 similar ISIN tasks in avg 35 min. In working hours. Only 2 active tasks.",
  "strengths": ["ISIN Specialist", "In Working Hours", "Low Workload"],
  "risks": ["None"],
  "est_resolution_min": 35
}]
```

### WF2: Chatbot Agent (Agentic)

**Nodes**: Webhook → AI Agent (GPT-4o-mini) → Respond to Webhook
**Tools (7)**: Get Active Tasks, Get SLA Breaches, Get Team Availability, Get Leave Schedule, Get Task Stats, Get Queue Workload, Get Resolution History

The LLM **autonomously decides** which tools to call based on the user's question:
```
User: "SLA breaches today"          → Agent calls: Get SLA Breaches
User: "Who is available?"           → Agent calls: Get Team Availability + Get Leave Schedule
User: "Operations summary"          → Agent calls: Get Task Stats + Get SLA Breaches + Get Team Availability
User: "Best person for ISIN tasks?" → Agent calls: Get Team Availability + Get Resolution History
```

### WF3: Embedding Generator (Automation)

**Nodes**: Webhook → Fetch Task (Postgres) → Generate Embedding (OpenAI) → Store Embedding (Postgres) → Respond

This is deterministic automation (not agentic) — it always runs the same pipeline. That's appropriate for embedding generation.

---

## Step 4: Testing

### Test WF1 (Assignment)
```bash
curl -X POST https://n8n.yourdomain.com/webhook/ai-assign \
  -H "Content-Type: application/json" \
  -d '{
    "task_id": "test-1", "mode": "suggest",
    "task_context": { "ref": "TSK-TEST", "queue": "Instruments", "priority": "High", "field": "ISIN", "sla_deadline": "2025-03-01T10:00:00Z" },
    "eligible_analysts": [
      { "analyst_id": "a1@lseg.com", "name": "Test Analyst", "active_tasks": 2, "experience_yrs": 5, "speciality": ["ISIN"], "in_working_hours": true, "on_leave_today": false }
    ]
  }'
```

### Test WF2 (Chatbot)
```bash
curl -X POST https://n8n.yourdomain.com/webhook/chat \
  -H "Content-Type: application/json" \
  -d '{ "message": "How many SLA breaches do we have today?" }'
```

### Test WF3 (Embedding)
```bash
curl -X POST https://n8n.yourdomain.com/webhook/embed-task \
  -H "Content-Type: application/json" \
  -d '{ "task_id": "YOUR_ACTUAL_TASK_ID" }'
```

### From the UI
1. Open UI → **AI Settings** → Toggle **n8n** ON
2. Enter your 3 webhook URLs
3. Click **AI Assign** on any task → should call WF1 and show ranked analysts
4. Open chatbot → ask "SLA breaches today" → should call WF2
5. Create a new task → should trigger WF3 (embedding) in the background

---

## How the Agentic Flow Works End-to-End

### Single Task Assignment

```
1. User clicks "⚡ AI Assign" on a task
2. Frontend (lseg-app.js):
   a. Filters eligible analysts (same queue + same domain) — PREREQUISITES ONLY
   b. Sends RAW analyst data to n8n: { task_context, eligible_analysts }
   c. No scoring by frontend — AI Agent does everything
3. n8n AI Agent (GPT-4o):
   a. Reads eligible analysts and task context
   b. DECIDES: "This is an ISIN task, let me check who resolved similar ones"
   c. Calls Tool: Find Similar Resolved Tasks (autonomous decision)
   d. REASONS: "Analyst X resolved 5 similar tasks in avg 28 min"
   e. Scores all analysts on 6 dimensions including working hours
   f. Returns top 3 with intelligent reasoning
4. Frontend renders modal with ranked analysts + assign buttons
```

### Auto-Assign on Task Creation

```
1. User creates task with auto-assign ON
2. Frontend: creates task → fires embedding (WF3) → sends eligible analysts to WF1
3. n8n AI Agent scores and returns top analyst
4. Frontend assigns top-ranked analyst automatically
5. Shows notification: "TSK-xxx assigned to John Smith via AI AUTO"
```

---

## Raspberry Pi Tips

### Memory
n8n typically uses 200-400 MB RAM. If your Pi is tight:
```yaml
# In docker-compose.yml under n8n service:
deploy:
  resources:
    limits:
      memory: 512M
```

### Logs
```bash
docker compose logs -f --tail=100 n8n
```

### Updates
```bash
cd ~/n8n
docker compose pull
docker compose up -d
```

---

## Appendix A: Troubleshooting

| Issue | Solution |
|-------|----------|
| Webhook returns 404 | Workflow not activated. Toggle it ON in n8n. |
| Webhook returns 502 | Cloudflare tunnel not running. Check `cloudflared` service. |
| AI Agent returns empty | Check OpenAI credential. Check execution log in n8n. |
| "CORS error" in browser | Add `N8N_EDITOR_BASE_URL=https://n8n.yourdomain.com` to docker env. |
| Agent doesn't call tools | Normal for simple tasks. Check execution trace to verify it's reasoning. |
| Slow response (>10s) | OpenAI latency. Switch to `gpt-4o-mini` in WF1 for faster responses. |
| Pi running out of memory | Add `deploy.resources.limits.memory: 512M` to docker-compose. |
| Postgres SSL error | Ensure SSL is enabled in the n8n Postgres credential. |

## Appendix B: Security

### Webhook Authentication
In each Webhook node → **Authentication** → **Header Auth**:
- Header Name: `X-API-Key`
- Header Value: generate with `openssl rand -hex 32`

Then in `lseg-app.js`, add the header to all fetch calls:
```javascript
headers: { 'Content-Type': 'application/json', 'X-API-Key': 'your-key' }
```

### Cloudflare Access (Optional)
Add a Cloudflare Access policy on `n8n.yourdomain.com`:
- Allow: your email / IP range
- Exception: webhook paths (use Service Auth rule)
