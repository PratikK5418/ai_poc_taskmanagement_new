# LSEG Data Operations Hub — Production-Grade Agentic AI Guide

## Table of Contents
1. [Scalability Analysis](#1-scalability-analysis)
2. [Architecture](#2-architecture)
3. [AI Concepts & When to Use Each](#3-ai-concepts)
4. [Database Setup: Embeddings & Indexes](#4-database-setup)
5. [Embedding Strategy: Generate, Store, Update](#5-embedding-strategy)
6. [n8n Workflow 1: AI Task Assignment](#6-workflow-1-assignment)
7. [n8n Workflow 2: Batch Auto-Assign](#7-workflow-2-batch)
8. [n8n Workflow 3: Chatbot Agent](#8-workflow-3-chatbot)
9. [n8n Workflow 4: Embedding Generator](#9-workflow-4-embeddings)
10. [n8n Workflow 5: Proactive SLA Monitor](#10-workflow-5-sla-cron)
11. [Frontend Integration](#11-frontend-integration)
12. [Production Deployment Checklist](#12-production-checklist)
13. [Cost Estimation](#13-cost-estimation)
14. [Demo Script](#14-demo-script)

---

## 1. Scalability Analysis

### Your Production Numbers

| Metric | Volume | Impact |
|--------|--------|--------|
| Total tasks | 1,000s (growing) | DB indexing critical |
| New tasks/day | 200–300 | Assignment throughput matters |
| Failed outcomes/task | 1–300 | Embedding text varies in length |
| Total FOs/day | Up to 90,000 | Bulk insert performance |
| Analysts | ~50 across queues | Small dataset, always in memory |
| Queues | ~10 | Small dataset |

### What Scales and What Doesn't

| Component | Current Approach | Scalable? | Production Approach |
|-----------|-----------------|-----------|-------------------|
| Task loading | Load ALL into JS array | ❌ At 10K+ tasks | **Paginate**: load only active (non-Resolved/Closed), max 500 |
| AI Assign (single) | SQL pre-filter → 1 LLM call | ✅ Fine | SQL narrows to top 5 candidates, LLM re-ranks with reasoning |
| Bulk Auto-Assign | SQL pre-filter → batched LLM | ✅ Efficient | Batch 10 tasks per LLM call. 30 tasks = 3 LLM calls, not 30 |
| Chatbot | n8n Agent with SQL tools | ✅ Fine | Single LLM call per question, SQL is fast |
| Embedding generation | Not implemented | — | **Async n8n workflow** triggered on task creation |
| Similar task search | Not implemented | — | **pgvector** cosine similarity, HNSW index |
| FO insert | Sequential per-row | ❌ At 300 FOs | **Batch insert** (already done) |

### The Efficient Agentic LLM Strategy

The AI Agent does **all the heavy lifting** — scoring, ranking, reasoning. SQL only handles prerequisites.

```
Every Assignment (single or batch):
  Step 1: Prerequisite Filter (fast, free, <10ms)
  ├── Filters eligible analysts by same queue + same domain
  ├── Returns raw analyst data (no scoring)
  └── Cost: $0 (pure filter)

  Step 2: AI Agent Scores + Ranks (intelligent, agentic)
  ├── Receives eligible analysts with raw data
  ├── Autonomously calls tools: similar tasks, leave schedule, analyst detail
  ├── Scores on 5 dimensions: Availability, Workload, Speciality, Experience, SLA Fit
  ├── Returns: ranked analysts with natural language reasoning
  └── Cost: ~$0.01-0.03 per call
```

**Why this is efficient:**
- LLM receives **pre-computed data** (5 candidates, not 50 analysts) → 80% fewer tokens
- Batch mode: **10 tasks per LLM call** → 10x fewer API calls
- SQL does the expensive filtering → LLM only adds the "intelligence layer"

| Scenario | LLM Calls | Cost | Time |
|----------|-----------|------|------|
| Single task (AI Assign click) | 1 call (GPT-4o) | $0.03 | 2-3s |
| 10 tasks (batch) | 1 call (GPT-4o-mini) | $0.01 | 3-5s |
| 50 tasks (bulk assign) | 5 calls (GPT-4o-mini) | $0.05 | 15-20s |
| 300 tasks/day (auto-assign) | 30 calls (GPT-4o-mini) | $0.30 | ~2 min |

---

## 2. Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                        LSEG DATA OPS HUB                            │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌──────────┐   webhook    ┌─────────────────────────────────────┐  │
│  │  UI      │ ───────────► │  n8n (5 Workflows)                  │  │
│  │  Browser │ ◄──────────  │                                     │  │
│  │          │   JSON       │  WF1: AI Assign (single, LLM)      │  │
│  └──────────┘              │  WF2: Batch Auto-Assign (SQL+LLM)  │  │
│                            │  WF3: Chatbot Agent (LLM+tools)    │  │
│                            │  WF4: Embed Generator (async)       │  │
│                            │  WF5: SLA Monitor (cron, 30min)    │  │
│                            └──────────┬──────────────────────────┘  │
│                                       │                              │
│                            ┌──────────▼──────────────────────────┐  │
│                            │  Supabase (PostgreSQL + pgvector)   │  │
│                            │                                     │  │
│                            │  Tables:                            │  │
│                            │  ├── tasks (+ task_embedding)       │  │
│                            │  ├── failed_outcomes                │  │
│                            │  ├── analysts                       │  │
│                            │  ├── analyst_leaves                 │  │
│                            │  ├── resolution_history             │  │
│                            │  ├── ai_assignment_scores           │  │
│                            │  ├── task_status_log                │  │
│                            │  └── config                         │  │
│                            │                                     │  │
│                            │  Indexes:                           │  │
│                            │  ├── HNSW on task_embedding         │  │
│                            │  ├── B-tree on sla_deadline         │  │
│                            │  ├── B-tree on status + queue_id    │  │
│                            │  └── B-tree on assignee_id          │  │
│                            └─────────────────────────────────────┘  │
│                                                                      │
│                            ┌─────────────────────────────────────┐  │
│                            │  OpenAI API                         │  │
│                            │  ├── GPT-4o / GPT-4o-mini (LLM)    │  │
│                            │  └── text-embedding-3-small (embed) │  │
│                            └─────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 3. AI Concepts & When to Use Each

### Concept Map

| Concept | What It Is | Used Where | Why Here |
|---------|-----------|------------|----------|
| **Agentic AI** | LLM autonomously picks which tools to call | Chatbot, Assignment | User asks free-form question → AI decides which SQL to run |
| **RAG** | Retrieve data → inject into prompt → generate answer | All workflows | Query DB first, then ask LLM to reason over results |
| **Tool-Use** | LLM calls functions/APIs as intermediate steps | Chatbot (6 SQL tools) | AI picks "Get SLA Breaches" tool when user asks about SLA |
| **Embeddings** | Convert text → 1536-dim vector for similarity | Task matching, assignment | Find "tasks like this one" for better scoring |
| **Vector Search** | Find nearest vectors using cosine distance | Similar task lookup | "Who resolved similar tasks fastest?" |
| **Chain-of-Thought** | LLM explains reasoning step by step | Assignment reasoning | "Ranked John #1 because..." |
| **Structured Output** | LLM returns JSON in a specific schema | Assignment response | Ensures UI can parse the response |

### What You Do NOT Need

| Concept | Why Not |
|---------|---------|
| **Document Chunking** | Your data is structured SQL rows, not PDFs/docs |
| **Fine-Tuning** | GPT-4o with good prompts is sufficient for this use case |
| **Autonomous Agents** (multi-step planning) | Your workflows are well-defined, not open-ended |
| **Memory/Context Window Management** | Single-turn Q&A, no multi-turn agent loops |

---

## 4. Database Setup: Embeddings & Indexes

Run this SQL in your Supabase SQL Editor **after** the existing `supabase-setup.sql`:

```sql
-- ============================================================
-- PRODUCTION AI SETUP — Embeddings, Indexes, Functions
-- ============================================================

-- 1. Enable pgvector extension (if not already enabled)
CREATE EXTENSION IF NOT EXISTS vector;

-- 2. Ensure task_embedding column exists (vector dimension 1536)
--    text-embedding-3-small outputs 1536 dimensions
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'tasks' AND column_name = 'task_embedding'
  ) THEN
    ALTER TABLE tasks ADD COLUMN task_embedding vector(1536);
  END IF;
END $$;

-- 3. Add HNSW index for fast vector similarity search
--    HNSW = Hierarchical Navigable Small World — best for < 1M vectors
--    Supports cosine distance operator (<=>)
CREATE INDEX IF NOT EXISTS idx_tasks_embedding_hnsw
  ON tasks USING hnsw (task_embedding vector_cosine_ops)
  WITH (m = 16, ef_construction = 64);

-- 4. Performance indexes for production queries
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_queue_status ON tasks(queue_id, status);
CREATE INDEX IF NOT EXISTS idx_tasks_assignee ON tasks(assignee_id);
CREATE INDEX IF NOT EXISTS idx_tasks_sla ON tasks(sla_deadline)
  WHERE status NOT IN ('Resolved', 'Closed');
CREATE INDEX IF NOT EXISTS idx_tasks_created ON tasks(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_tasks_unassigned ON tasks(queue_id)
  WHERE assignee_id IS NULL AND status = 'New';
CREATE INDEX IF NOT EXISTS idx_fo_task ON failed_outcomes(task_id);

-- 5. Function: Find similar past tasks using vector search
--    Returns top N resolved tasks most similar to the given embedding
CREATE OR REPLACE FUNCTION find_similar_tasks(
  query_embedding vector(1536),
  match_count int DEFAULT 5,
  similarity_threshold float DEFAULT 0.5
)
RETURNS TABLE (
  task_id text,
  task_ref text,
  field text,
  rule text,
  queue_id text,
  assignee_id text,
  resolution_mins float,
  similarity float
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    t.id as task_id,
    t.ref as task_ref,
    t.field,
    t.rule,
    t.queue_id,
    t.assignee_id,
    EXTRACT(EPOCH FROM (t.resolved_at - t.activated_at))/60 as resolution_mins,
    1 - (t.task_embedding <=> query_embedding) as similarity
  FROM tasks t
  WHERE t.status = 'Resolved'
    AND t.task_embedding IS NOT NULL
    AND 1 - (t.task_embedding <=> query_embedding) > similarity_threshold
  ORDER BY t.task_embedding <=> query_embedding
  LIMIT match_count;
END;
$$ LANGUAGE plpgsql;

-- 6. Function: Get best analysts for similar tasks
--    "Who resolved tasks like this one fastest?"
CREATE OR REPLACE FUNCTION get_best_analysts_for_similar_tasks(
  query_embedding vector(1536),
  target_queue_id text,
  match_count int DEFAULT 10
)
RETURNS TABLE (
  analyst_id text,
  analyst_name text,
  similar_tasks_resolved int,
  avg_resolution_mins float,
  avg_similarity float
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    a.id as analyst_id,
    a.full_name as analyst_name,
    COUNT(t.id)::int as similar_tasks_resolved,
    ROUND(AVG(EXTRACT(EPOCH FROM (t.resolved_at - t.activated_at))/60)::numeric, 1)::float as avg_resolution_mins,
    ROUND(AVG(1 - (t.task_embedding <=> query_embedding))::numeric, 3)::float as avg_similarity
  FROM tasks t
  JOIN analysts a ON a.id = t.assignee_id
  WHERE t.status = 'Resolved'
    AND t.task_embedding IS NOT NULL
    AND t.queue_id = target_queue_id
    AND 1 - (t.task_embedding <=> query_embedding) > 0.5
  GROUP BY a.id, a.full_name
  ORDER BY avg_resolution_mins ASC
  LIMIT match_count;
END;
$$ LANGUAGE plpgsql;

-- 7. Function: SQL-based scoring fallback (used when n8n is OFF)
--    6 dimensions: Availability 20%, Workload 20%, Speciality 20%, Working Hours 15%, Experience 13%, SLA Fit 12%
--    Prerequisites: same queue + same domain (not scored, just filtered)
CREATE OR REPLACE FUNCTION score_analysts_for_task(p_task_id text)
RETURNS TABLE (
  analyst_id text,
  analyst_name text,
  overall_score int,
  avail_score int,
  workload_score int,
  spec_score int,
  wh_score int,
  exp_score int,
  sla_score int,
  reasoning text
) AS $$
DECLARE
  v_queue_id text;
  v_domain_id text;
  v_field text;
  v_sla_deadline timestamptz;
  v_avg_active float;
BEGIN
  SELECT t.queue_id, t.domain_id, t.field, t.sla_deadline
  INTO v_queue_id, v_domain_id, v_field, v_sla_deadline
  FROM tasks t WHERE t.id = p_task_id;

  -- Team average for relative workload comparison
  SELECT COALESCE(AVG(a.active_tasks), 1)
  INTO v_avg_active
  FROM analysts a
  WHERE v_queue_id = ANY(a.queue_ids)
    AND (v_domain_id IS NULL OR v_domain_id = ANY(a.domain_ids));

  RETURN QUERY
  SELECT
    a.id as analyst_id,
    a.full_name as analyst_name,
    (
      CASE WHEN EXISTS (
        SELECT 1 FROM analyst_leaves al
        WHERE al.analyst_id = a.id
          AND al.date_from <= CURRENT_DATE AND al.date_to >= CURRENT_DATE
      ) THEN 25 ELSE 100 END * 20  -- Availability 20%
      +
      GREATEST(0, LEAST(100, ROUND((1 - a.active_tasks::float / GREATEST(v_avg_active * 2, 1)) * 100)::int)) * 20  -- Workload 20%
      +
      CASE WHEN v_field IS NOT NULL AND v_field = ANY(a.speciality) THEN 100 ELSE 40 END * 20  -- Speciality 20%
      +
      CASE WHEN a.working_hrs_from IS NULL THEN 70
           WHEN CURRENT_TIME BETWEEN a.working_hrs_from AND a.working_hrs_to THEN 100
           ELSE 20 END * 15  -- Working Hours 15%
      +
      LEAST(100, COALESCE(a.experience_yrs, 0) * 14) * 13  -- Experience 13%
      +
      CASE
        WHEN v_sla_deadline < NOW() THEN 100
        WHEN v_sla_deadline < NOW() + INTERVAL '2 hours' THEN 80
        ELSE 60
      END * 12  -- SLA Fit 12%
    ) / 100 as overall_score,
    CASE WHEN EXISTS (
      SELECT 1 FROM analyst_leaves al
      WHERE al.analyst_id = a.id
        AND al.date_from <= CURRENT_DATE AND al.date_to >= CURRENT_DATE
    ) THEN 25 ELSE 100 END as avail_score,
    GREATEST(0, LEAST(100, ROUND((1 - a.active_tasks::float / GREATEST(v_avg_active * 2, 1)) * 100)::int)) as workload_score,
    CASE WHEN v_field IS NOT NULL AND v_field = ANY(a.speciality) THEN 100 ELSE 40 END as spec_score,
    CASE WHEN a.working_hrs_from IS NULL THEN 70
         WHEN CURRENT_TIME BETWEEN a.working_hrs_from AND a.working_hrs_to THEN 100
         ELSE 20 END as wh_score,
    LEAST(100, COALESCE(a.experience_yrs, 0) * 14) as exp_score,
    CASE
      WHEN v_sla_deadline < NOW() THEN 100
      WHEN v_sla_deadline < NOW() + INTERVAL '2 hours' THEN 80
      ELSE 60
    END as sla_score,
    a.full_name || CASE WHEN EXISTS (
      SELECT 1 FROM analyst_leaves al WHERE al.analyst_id = a.id
        AND al.date_from <= CURRENT_DATE AND al.date_to >= CURRENT_DATE
    ) THEN ' is on leave today but can start when back.' ELSE ' is available.' END
    || ' Active: ' || a.active_tasks || ' tasks.'
    || CASE WHEN v_field IS NOT NULL AND v_field = ANY(a.speciality)
       THEN ' Has ' || v_field || ' expertise.' ELSE '' END
    || CASE WHEN a.working_hrs_from IS NOT NULL
       THEN CASE WHEN CURRENT_TIME BETWEEN a.working_hrs_from AND a.working_hrs_to
            THEN ' In working hours.' ELSE ' Outside working hours.' END
       ELSE '' END
    as reasoning
  FROM analysts a
  WHERE v_queue_id = ANY(a.queue_ids)
    AND (v_domain_id IS NULL OR v_domain_id = ANY(a.domain_ids))
  ORDER BY overall_score DESC
  LIMIT 3;
END;
$$ LANGUAGE plpgsql;

-- 8. View: Today's operational summary (for chatbot / dashboard)
CREATE OR REPLACE VIEW ops_summary AS
SELECT
  COUNT(*) FILTER (WHERE status NOT IN ('Resolved','Closed')) as active_tasks,
  COUNT(*) FILTER (WHERE status = 'New') as new_tasks,
  COUNT(*) FILTER (WHERE assignee_id IS NULL AND status = 'New') as unassigned,
  COUNT(*) FILTER (WHERE sla_deadline < NOW() AND status NOT IN ('Resolved','Closed')) as sla_breached,
  COUNT(*) FILTER (WHERE sla_deadline BETWEEN NOW() AND NOW() + INTERVAL '4 hours'
    AND status NOT IN ('Resolved','Closed')) as sla_at_risk,
  COUNT(*) FILTER (WHERE status = 'Resolved') as resolved_today,
  COUNT(*) FILTER (WHERE status = 'Blocked') as blocked
FROM tasks
WHERE created_at >= CURRENT_DATE;

-- 9. Add use_n8n to config defaults
INSERT INTO config (key, value) VALUES
  ('use_n8n', '{"enabled": false}'::jsonb)
ON CONFLICT (key) DO NOTHING;
```

---

## 5. Embedding Strategy: Generate, Store, Update

### What Gets Embedded

| Data | Text to Embed | Column | When |
|------|--------------|--------|------|
| **Task** | `"Queue: {queue} | Domain: {domain} | Field: {field} | Rule: {rule} | Priority: {priority} | Description: {desc}"` | `tasks.task_embedding` | On task creation |
| **Resolution** | Same as task + resolution notes | `resolution_history.outcome_embedding` | On task resolve |

### Embedding Model: `text-embedding-3-small`

| Property | Value |
|----------|-------|
| Model | `text-embedding-3-small` |
| Dimensions | 1536 |
| Cost | **$0.02 per 1M tokens** (~$0.00001 per task) |
| Speed | ~50ms per call |
| At 300 tasks/day | **$0.003/day** = $0.09/month |

### How Embedding Generation Works

```
Task Created in UI
        │
        ▼
UI calls POST /webhook/embed-task
        │
        ▼
n8n Workflow 4:
  1. Receive task_id
  2. Fetch task details from Supabase
  3. Build text: "Queue: Instruments | Field: ISIN | Rule: Not Null | ..."
  4. Call OpenAI Embeddings API → get 1536-dim vector
  5. UPDATE tasks SET task_embedding = vector WHERE id = task_id
        │
        ▼
Embedding stored in pgvector column
        │
        ▼
Available for similarity search in future assignments
```

### How Embeddings Improve Assignment

```
Without Embeddings (current):
  Score = availability + workload + queue_match + experience
  → "John is available and in this queue" (generic)

With Embeddings:
  1. Find 5 most similar past resolved tasks
  2. See: "Analyst X resolved 3 similar ISIN tasks in avg 35 min"
  3. See: "Analyst Y resolved 0 similar tasks"
  Score = availability + workload + queue_match + experience + SIMILAR_TASK_BONUS
  → "John resolved 3 similar ISIN null-check tasks in avg 35 min" (specific, evidence-based)
```

### How to Update Embeddings

| Event | Action |
|-------|--------|
| Task created | Generate embedding immediately via n8n WF4 |
| Task description edited | Re-generate embedding (call WF4 again) |
| Task resolved | Copy embedding to resolution_history |
| Bulk import | Batch-generate via n8n cron (process tasks where task_embedding IS NULL) |

---

## 6. n8n Workflow 1: AI Task Assignment (Single Task, Interactive)

**Trigger**: User clicks "⚡ AI Assign" on a specific task.
**Latency target**: < 3 seconds (user is waiting).
**Uses LLM**: Yes — **GPT-4o** for high-quality reasoning.

### How Efficient Single Assignment Works

```
Frontend (lseg-app.js):
  1. SQL pre-filters top 5 candidates (free, <10ms)     ← ALREADY DONE
  2. Sends task_context + pre_filtered_candidates to n8n ← COMPACT payload

n8n Workflow:
  3. (Optional) Fetch similar past tasks via embedding search
  4. LLM re-ranks candidates with intelligent reasoning
  5. Returns top 3 with scores, reasoning, strengths, risks
```

**Key efficiency**: The frontend sends pre-computed candidates with scores.
The LLM doesn't need to query analyst data — it's already in the payload.
This reduces LLM tokens by **~80%** compared to querying everything in n8n.

### n8n Setup Instructions

#### Step 1: Install n8n

**Option A: Docker (recommended)**
```bash
docker run -it --rm --name n8n -p 5678:5678 \
  -v n8n_data:/home/node/.n8n \
  n8nio/n8n
```

**Option B: npm**
```bash
npm install -g n8n
n8n start
```

Open **http://localhost:5678** → create your account.

#### Step 2: Add Credentials

Go to **Settings → Credentials**:

**OpenAI Credential:**
- Name: `OpenAI`
- API Key: from https://platform.openai.com/api-keys

**Postgres Credential:**
- Name: `Supabase DB`
- Type: **Postgres**
- Host: `db.hsnzhluqydtlxsrymvdr.supabase.co`
- Port: `5432`
- Database: `postgres`
- User: `postgres`
- Password: Your Supabase database password (Project Settings → Database)
- SSL: Enable

#### Step 3: Create Workflow

Create new workflow → name it **"AI Task Assignment"**

**Node 1: Webhook (Trigger)**
- HTTP Method: `POST`
- Path: `ai-assign`
- Response Mode: **Last Node**
- This creates: `https://your-n8n-host/webhook/ai-assign`
- Receives payload:
```json
{
  "task_id": "task-xxx",
  "mode": "suggest",
  "task_context": {
    "ref": "TSK-100", "queue": "Instruments", "queue_id": "instruments",
    "priority": "High", "field": "ISIN", "rule": "Not Null",
    "description": "...", "sla_deadline": "2025-02-28T10:00:00Z",
    "outcomes_count": 15, "open_count": 12
  },
  "pre_filtered_candidates": [
    {
      "analyst_id": "john@example.com", "name": "John Smith",
      "sql_score": 82, "scores": { "Availability": 100, "Workload": 80, ... },
      "reasoning": "John Smith is available today. Current workload: 2 active tasks.",
      "strengths": ["Low Workload", "Available Today"], "risks": [],
      "est_resolution_min": 45
    },
    ...
  ]
}
```

**Node 2: Postgres — Find Similar Past Tasks (embedding search, optional)**
```sql
SELECT t.ref, t.field, t.rule, t.assignee_id, a.full_name,
  EXTRACT(EPOCH FROM (t.resolved_at - t.activated_at))/60 as resolution_mins,
  1 - (t.task_embedding <=> (
    SELECT task_embedding FROM tasks WHERE id = '{{ $json.body.task_id }}'
  )) as similarity
FROM tasks t
LEFT JOIN analysts a ON a.id = t.assignee_id
WHERE t.status = 'Resolved'
  AND t.task_embedding IS NOT NULL
  AND t.id != '{{ $json.body.task_id }}'
ORDER BY t.task_embedding <=> (
  SELECT task_embedding FROM tasks WHERE id = '{{ $json.body.task_id }}'
)
LIMIT 5
```
> Note: This returns empty if no embeddings exist yet. The workflow still works without it.

**Node 3: AI Agent (OpenAI GPT-4o)**
- Type: **AI Agent**
- Model: **gpt-4o** (interactive — user expects high quality)
- System Prompt:

```
You are an AI task assignment agent for LSEG Data Operations.
Your job: re-rank pre-filtered analyst candidates for a task and provide intelligent reasoning.

The candidates have already been scored by SQL. You add intelligence:
- Nuanced reasoning based on task specifics
- Similar task history bonus
- Edge case detection
- Better explanations than SQL can generate

TASK TO ASSIGN:
{{ $json.body.task_context }}

PRE-FILTERED CANDIDATES (already scored by SQL):
{{ $json.body.pre_filtered_candidates }}

SIMILAR PAST TASKS (resolved, by embedding similarity):
{{ $node["Find Similar Past Tasks"].json }}

YOUR SCORING ADJUSTMENTS:
- Start with the sql_score as baseline
- BOOST if analyst resolved similar past tasks: "Resolved X similar tasks in avg Y min"
- BOOST if analyst has domain-specific skills matching the task field
- PENALIZE if analyst is overloaded relative to others
- ADJUST for SLA urgency: if sla_deadline is close, prefer fastest resolvers

RULES:
1. On-leave analysts CAN still be assigned — they just start when back. Score them lower but don't exclude them. If an on-leave analyst is the best specialist for a task, they can still be ranked #1 with a note about when they'll start.
2. Re-rank the candidates 0-100
3. Return top 3 ranked
4. Provide clear 2-3 sentence reasoning for each, citing specific data points
5. Include estimated resolution time based on their history

Return ONLY a valid JSON array — no markdown fences, no extra text:
[{
  "analyst_id": "email@example.com",
  "overall_score": 85,
  "scores": {
    "Availability": 100,
    "Workload": 80,
    "Speciality": 90,
    "Working Hours": 100,
    "Experience": 70,
    "SLA Fit": 85
  },
  "reasoning": "John resolved 3 similar ISIN null-check tasks in avg 35 min. Available today with only 2 active tasks. Strong queue expertise.",
  "strengths": ["ISIN Specialist", "Low Workload", "Fast Resolver"],
  "risks": ["None identified"],
  "est_resolution_min": 35
}]
```

**Node 4: Respond to Webhook**
- Response Body: `{{ $json.output || $json.text || $json }}`
- Response Headers: `Content-Type: application/json`

**Wiring:**
```
Webhook ─► Find Similar Past Tasks ─► AI Agent ─► Respond to Webhook
```

> **Note**: Unlike the old approach with 5 parallel DB queries, this workflow only needs 1 optional DB query (embedding search). All analyst data is already in the webhook payload from the frontend's SQL pre-filter. This makes the workflow **simpler, faster, and cheaper**.

---

## 7. n8n Workflow 2: Batch Auto-Assign (Efficient Agentic LLM)

**Trigger**: User clicks "⚡ AI Auto-Assign All" or daily cron.
**Latency target**: < 30 seconds for 50 tasks.
**Uses LLM**: Yes — **GPT-4o-mini**, batched efficiently (10 tasks per call).

This is the **Agentic** path: LLM is always involved, but SQL does the heavy lifting first.

### How Efficient Batch LLM Works

```
Frontend (lseg-app.js):
  1. SQL pre-filters all unassigned tasks (top 3 candidates each)  — FREE
  2. Groups into batches of 10 tasks
  3. Sends each batch to n8n with pre-filtered candidates

n8n Workflow:
  4. LLM (GPT-4o-mini) processes 10 tasks in ONE call
  5. LLM does cross-task load balancing (won't overload one analyst)
  6. Returns assignment for each task with reasoning
  7. Executes assignments in Supabase
```

| | Naive LLM (per task) | Efficient Agentic LLM (batched) |
|--|---------------------|-------------------------------|
| 30 tasks | 30 API calls, $0.90, 90s | **3 calls**, $0.03, 15s |
| 300 tasks | 300 calls, $9, 15 min | **30 calls**, $0.30, ~2 min |
| Intelligence | Individual context only | **Cross-task load balancing** |
| Token usage | Full context per call | Pre-filtered (80% fewer tokens) |

### Nodes

**Node 1: Webhook (Trigger)**
- HTTP Method: `POST`
- Path: `batch-assign`
- Response Mode: **Last Node**
- Receives: `{ mode: "batch_assign", tasks: [...] }` where each task has `pre_filtered_candidates`

**Node 2: AI Agent (OpenAI GPT-4o-mini) — Batch Assignment**
- Type: **AI Agent**
- Model: **gpt-4o-mini** (fast, cheap, perfect for batch)
- System Prompt:

```
You are an AI task assignment agent for LSEG Data Operations.
You receive a batch of tasks, each with pre-filtered candidate analysts scored by SQL.

YOUR JOB:
1. Review each task and its pre-filtered candidates
2. Select the BEST analyst for each task
3. Do CROSS-TASK LOAD BALANCING: if the same analyst is top-ranked for multiple tasks,
   redistribute to avoid overloading them (consider their current active_tasks)
4. Provide brief reasoning for each assignment

IMPORTANT RULES:
- On-leave analysts CAN be assigned (they start when back) — score them lower but don't exclude
- Prefer the SQL top-ranked candidate unless you have a good reason to change
- If reassigning due to load balancing, explain why
- Consider SLA urgency: assign urgent tasks to faster resolvers

TASKS TO ASSIGN:
{{ $json.body.tasks }}

Return ONLY a valid JSON array — no markdown, no extra text:
[{
  "task_id": "task-xxx",
  "analyst_id": "email@example.com",
  "overall_score": 85,
  "reasoning": "Selected based on lowest workload and ISIN speciality on similar tasks.",
  "scores": { "Availability": 100, "Workload": 80, "Speciality": 90, "Working Hours": 100, "Experience": 70, "SLA Fit": 85 }
}]
```

**Node 3: Code — Parse LLM Response**
```javascript
const output = $input.first().json;
let assignments = [];
try {
  const text = output.output || output.text || JSON.stringify(output);
  assignments = JSON.parse(text);
} catch (e) {
  // Try to extract JSON array from text
  const match = text.match(/\[[\s\S]*\]/);
  if (match) assignments = JSON.parse(match[0]);
}
return assignments.map(a => ({ json: a }));
```

**Node 4: Postgres — Execute Assignments** (Loop over each)
```sql
UPDATE tasks SET
  assignee_id = '{{ $json.analyst_id }}',
  assigned_by = 'AI_AUTO_BATCH',
  status = 'Active',
  ai_confidence = {{ $json.overall_score }},
  activated_at = NOW(),
  updated_at = NOW()
WHERE id = '{{ $json.task_id }}' AND assignee_id IS NULL;

UPDATE analysts SET
  active_tasks = COALESCE(active_tasks, 0) + 1,
  updated_at = NOW()
WHERE id = '{{ $json.analyst_id }}';
```

**Node 5: Respond to Webhook**
```json
{ "assignments": {{ $node["Execute Assignments"].json }}, "assigned": {{ $node["Execute Assignments"].json.length }}, "method": "AGENTIC_BATCH_LLM" }
```

### Why This Is Better Than SQL-Only Batch

The LLM adds intelligence that SQL cannot:
- **Cross-task load balancing**: "Analyst A is top for 5 tasks, redistribute 3 to Analyst B"
- **Nuanced reasoning**: "Task has unusual ISIN + LEI combo, prefer specialist despite higher workload"
- **SLA-aware prioritization**: "Route critical SLA-breach to fastest resolver, not just lowest workload"
- **Natural language reasoning**: Every assignment comes with an explanation

---

## 8. n8n Workflow 3: Chatbot Agent (Agentic with Tools)

**Trigger**: User sends a message in the chat panel.
**Uses LLM**: Yes (single call per question, AI picks tools).

This is genuinely **agentic**: the AI autonomously decides which SQL queries to run based on the user's natural language question.

### Nodes

**Node 1: Webhook (Trigger)**
- HTTP Method: `POST`
- Path: `chat`
- Response Mode: **Last Node**

**Node 2: AI Agent (with Tool sub-nodes)**
- Type: **AI Agent**
- Model: **gpt-4o-mini** (cheaper, fast enough for chat)
- System Prompt:

```
You are the LSEG Data Operations AI Assistant. You help operations managers
monitor tasks, SLA compliance, team availability, and workload.

You have access to database tools. ALWAYS use them to get live data.
Never guess or make up numbers. Always provide specific counts and details.

Today's date: {{ new Date().toISOString().split('T')[0] }}

FORMATTING RULES:
- Use bullet points (•) for lists
- Bold important items with **text**
- Include specific numbers (counts, times, percentages)
- If data is empty, say so clearly ("No tasks found matching...")
- Provide actionable recommendations when relevant
- Keep answers concise but complete
```

**Tool Sub-Nodes** (each is a Postgres node attached to the AI Agent):

**Tool 1: "get_active_tasks"**
- Description: "Get all active (non-resolved, non-closed) tasks with SLA, assignees, and queue info. Use this for questions about current tasks, task counts, or task status."
```sql
SELECT t.id, t.ref, t.status, t.priority, t.field, t.rule,
  t.sla_deadline, t.assignee_id, t.outcomes_count, t.open_count,
  t.created_at, q.name as queue_name, a.full_name as assignee_name,
  EXTRACT(EPOCH FROM (t.sla_deadline - NOW()))/3600 as hours_to_sla
FROM tasks t
LEFT JOIN queues q ON q.id = t.queue_id
LEFT JOIN analysts a ON a.id = t.assignee_id
WHERE t.status NOT IN ('Resolved', 'Closed')
ORDER BY t.sla_deadline ASC
LIMIT 100
```

**Tool 2: "get_sla_breaches"**
- Description: "Get tasks that have breached SLA or will breach within 4 hours. Use for SLA monitoring questions."
```sql
SELECT t.ref, t.field, t.priority, t.status, t.sla_deadline,
  a.full_name as assignee_name, q.name as queue_name,
  ROUND(EXTRACT(EPOCH FROM (t.sla_deadline - NOW()))/3600, 1) as hours_remaining
FROM tasks t
LEFT JOIN analysts a ON a.id = t.assignee_id
LEFT JOIN queues q ON q.id = t.queue_id
WHERE t.status NOT IN ('Resolved', 'Closed')
  AND t.sla_deadline < NOW() + INTERVAL '4 hours'
ORDER BY t.sla_deadline ASC
```

**Tool 3: "get_team_availability"**
- Description: "Get all analyst availability, current workload, skills, and leave status. Use for questions about team, who is available, workload distribution."
```sql
SELECT a.id, a.full_name, a.active_tasks, a.experience_yrs,
  a.avg_resolution_mins, a.working_hrs, a.timezone,
  array_to_string(a.queue_ids, ', ') as queues,
  array_to_string(a.speciality, ', ') as skills,
  CASE WHEN EXISTS (
    SELECT 1 FROM analyst_leaves al
    WHERE al.analyst_id = a.id
      AND al.date_from <= CURRENT_DATE AND al.date_to >= CURRENT_DATE
  ) THEN 'On Leave' ELSE 'Available' END as today_status
FROM analysts a ORDER BY a.full_name
```

**Tool 4: "get_upcoming_leaves"**
- Description: "Get all upcoming and current analyst leaves. Use for questions about leaves, time off, upcoming absences."
```sql
SELECT al.analyst_id, a.full_name, al.type, al.date_from, al.date_to,
  CASE WHEN al.date_from <= CURRENT_DATE AND al.date_to >= CURRENT_DATE
    THEN 'Currently on leave' ELSE 'Upcoming' END as leave_status
FROM analyst_leaves al
JOIN analysts a ON a.id = al.analyst_id
WHERE al.date_to >= CURRENT_DATE
ORDER BY al.date_from ASC
```

**Tool 5: "get_task_statistics"**
- Description: "Get task count breakdown by status and priority. Use for summary, statistics, or dashboard-type questions."
```sql
SELECT status, priority, COUNT(*) as count,
  COUNT(*) FILTER (WHERE assignee_id IS NULL) as unassigned,
  COUNT(*) FILTER (WHERE sla_deadline < NOW()) as sla_breached
FROM tasks
GROUP BY status, priority
ORDER BY
  CASE status WHEN 'New' THEN 1 WHEN 'Active' THEN 2 WHEN 'Blocked' THEN 3
    WHEN 'Resolved' THEN 4 WHEN 'Closed' THEN 5 END,
  CASE priority WHEN 'Critical' THEN 1 WHEN 'High' THEN 2
    WHEN 'Medium' THEN 3 WHEN 'Low' THEN 4 END
```

**Tool 6: "get_queue_details"**
- Description: "Get per-queue breakdown of active tasks, unassigned tasks, and SLA breaches. Use for queue-specific questions."
```sql
SELECT q.name as queue_name,
  COUNT(t.id) FILTER (WHERE t.status NOT IN ('Resolved','Closed')) as active_tasks,
  COUNT(t.id) FILTER (WHERE t.assignee_id IS NULL AND t.status NOT IN ('Resolved','Closed')) as unassigned,
  COUNT(t.id) FILTER (WHERE t.sla_deadline < NOW() AND t.status NOT IN ('Resolved','Closed')) as breached,
  COUNT(t.id) FILTER (WHERE t.status = 'Resolved' AND t.resolved_at >= CURRENT_DATE) as resolved_today
FROM queues q
LEFT JOIN tasks t ON t.queue_id = q.id
GROUP BY q.id, q.name
ORDER BY active_tasks DESC
```

**Tool 7: "search_similar_tasks"** (embedding-powered)
- Description: "Semantic search: find tasks similar to a given description. Use when user asks about specific types of tasks or patterns."
```sql
-- This tool is powerful but only works after embeddings are generated.
-- For the POC, this returns tasks matching keywords as a simpler alternative.
SELECT t.ref, t.field, t.rule, t.status, t.priority,
  q.name as queue_name, a.full_name as assignee_name,
  t.outcomes_count, t.sla_deadline
FROM tasks t
LEFT JOIN queues q ON q.id = t.queue_id
LEFT JOIN analysts a ON a.id = t.assignee_id
WHERE t.description ILIKE '%' || '{{ $json.search_term }}' || '%'
   OR t.field ILIKE '%' || '{{ $json.search_term }}' || '%'
   OR t.rule ILIKE '%' || '{{ $json.search_term }}' || '%'
ORDER BY t.created_at DESC
LIMIT 20
```

**Node 3: Respond to Webhook**
- Response Body: `{{ { output: $json.output || $json.text || JSON.stringify($json) } }}`

---

## 9. n8n Workflow 4: Embedding Generator (Async)

**Trigger**: Called by UI after task creation, or by cron for backfill.
**Uses**: OpenAI Embeddings API (not LLM).

### Nodes

**Node 1: Webhook (Trigger)**
- HTTP Method: `POST`
- Path: `embed-task`
- Response Mode: **Immediately respond** (don't make UI wait)
- Response: `{ "status": "embedding_queued" }`

**Node 2: Postgres — Fetch Task Details**
```sql
SELECT t.id, t.description, t.field, t.rule, t.priority,
  q.name as queue_name, d.name as domain_name
FROM tasks t
LEFT JOIN queues q ON q.id = t.queue_id
LEFT JOIN domains d ON d.id = t.domain_id
WHERE t.id = '{{ $json.body.task_id }}'
```

**Node 3: Code — Build Embedding Text**
```javascript
const task = $input.first().json;
const text = [
  `Queue: ${task.queue_name || 'Unknown'}`,
  `Domain: ${task.domain_name || 'Unknown'}`,
  `Field: ${task.field || 'General'}`,
  `Rule: ${task.rule || 'General validation'}`,
  `Priority: ${task.priority || 'Medium'}`,
  `Description: ${task.description || 'Validation failure batch'}`
].join(' | ');

return [{ json: { task_id: task.id, text: text } }];
```

**Node 4: HTTP Request — Call OpenAI Embeddings API**
- Method: `POST`
- URL: `https://api.openai.com/v1/embeddings`
- Authentication: **Header Auth** → `Authorization: Bearer YOUR_OPENAI_API_KEY`
- Body (JSON):
```json
{
  "model": "text-embedding-3-small",
  "input": "{{ $json.text }}"
}
```

**Node 5: Postgres — Store Embedding**
```sql
UPDATE tasks
SET task_embedding = '{{ JSON.stringify($json.data[0].embedding) }}'::vector
WHERE id = '{{ $node["Build Embedding Text"].json.task_id }}'
```

**Wiring:**
```
Webhook ─► Fetch Task ─► Build Text ─► OpenAI Embeddings ─► Store in DB
```

### Backfill Existing Tasks (Cron Variant)

Create a **second trigger** on this workflow (or a separate workflow):

**Trigger: Schedule (Cron)**
- Every: 5 minutes
- Find tasks without embeddings:

```sql
SELECT t.id, t.description, t.field, t.rule, t.priority,
  q.name as queue_name, d.name as domain_name
FROM tasks t
LEFT JOIN queues q ON q.id = t.queue_id
LEFT JOIN domains d ON d.id = t.domain_id
WHERE t.task_embedding IS NULL
LIMIT 20
```

Then loop through each result → Build Text → OpenAI → Store.

This backfills 20 tasks every 5 minutes = **240/hour**, clearing any backlog.

---

## 10. n8n Workflow 5: Proactive SLA Monitor (Cron)

**Trigger**: Runs every 30 minutes automatically.
**Purpose**: Early warning system for SLA breaches.

### Nodes

**Node 1: Schedule Trigger**
- Every: 30 minutes

**Node 2: Postgres — Find At-Risk Tasks**
```sql
SELECT t.ref, t.field, t.priority, t.status, t.sla_deadline,
  t.assignee_id, a.full_name as assignee_name, q.name as queue_name,
  ROUND(EXTRACT(EPOCH FROM (t.sla_deadline - NOW()))/3600, 1) as hours_remaining,
  t.outcomes_count,
  CASE
    WHEN t.sla_deadline < NOW() THEN 'BREACHED'
    WHEN t.sla_deadline < NOW() + INTERVAL '1 hour' THEN 'CRITICAL'
    WHEN t.sla_deadline < NOW() + INTERVAL '2 hours' THEN 'AT_RISK'
    ELSE 'WARNING'
  END as urgency
FROM tasks t
LEFT JOIN analysts a ON a.id = t.assignee_id
LEFT JOIN queues q ON q.id = t.queue_id
WHERE t.status NOT IN ('Resolved', 'Closed')
  AND t.sla_deadline < NOW() + INTERVAL '4 hours'
ORDER BY t.sla_deadline ASC
```

**Node 3: IF — Any Results?**
- Condition: `{{ $json.length > 0 }}`

**Node 4: Code — Format Alert**
```javascript
const tasks = $input.all().map(i => i.json);
const breached = tasks.filter(t => t.urgency === 'BREACHED');
const critical = tasks.filter(t => t.urgency === 'CRITICAL');
const unassigned = tasks.filter(t => !t.assignee_id);

let alert = `🚨 SLA ALERT — ${new Date().toLocaleString()}\n\n`;
alert += `BREACHED: ${breached.length} | CRITICAL: ${critical.length} | TOTAL AT RISK: ${tasks.length}\n`;
if (unassigned.length) alert += `⚠️ ${unassigned.length} AT-RISK TASKS ARE UNASSIGNED\n`;
alert += `\nDetails:\n`;
tasks.forEach(t => {
  alert += `• ${t.ref} (${t.priority}) — ${t.queue_name} — ${t.urgency} — ${t.hours_remaining}h left — ${t.assignee_name || 'UNASSIGNED'}\n`;
});

return [{ json: { alert, breached_count: breached.length, critical_count: critical.length, unassigned_count: unassigned.length } }];
```

**Node 5 (Optional): Slack / Email / Teams notification**
- Connect to your preferred notification channel
- For POC demo: just log to n8n execution history

**Node 6 (Optional): Auto-escalate unassigned critical tasks**
```sql
-- Auto-assign unassigned critical/high SLA-breached tasks
-- using SQL scoring (Tier 1)
WITH to_assign AS (
  SELECT t.id as task_id, (score_analysts_for_task(t.id)).analyst_id as best_analyst
  FROM tasks t
  WHERE t.assignee_id IS NULL
    AND t.status = 'New'
    AND t.priority IN ('Critical', 'High')
    AND t.sla_deadline < NOW() + INTERVAL '2 hours'
  LIMIT 10
)
UPDATE tasks SET
  assignee_id = to_assign.best_analyst,
  assigned_by = 'AI_ESCALATION',
  status = 'Active',
  activated_at = NOW()
FROM to_assign
WHERE tasks.id = to_assign.task_id
```

---

## 11. Frontend Integration

### Configuration in `lseg-app.js`

After activating all workflows in n8n, update:

```javascript
const N8N_ASSIGN_URL = 'https://your-n8n-host/webhook/ai-assign';
const N8N_CHAT_URL   = 'https://your-n8n-host/webhook/chat';
```

The batch and embedding endpoints are called separately:
```javascript
const N8N_BATCH_URL  = 'https://your-n8n-host/webhook/batch-assign';
const N8N_EMBED_URL  = 'https://your-n8n-host/webhook/embed-task';
```

### UI Toggle Behavior (already implemented)

| Toggle State | AI Assign | Auto-Assign All | Auto-Assign on Create | Chatbot | Embedding |
|-------------|-----------|-----------------|----------------------|---------|-----------|
| **n8n ON** | SQL pre-filter → WF1 LLM re-rank | SQL pre-filter → batched WF2 LLM | SQL pre-filter → WF1 LLM | WF3 (Agentic) | WF4 (async) |
| **n8n OFF** | SQL scoring only | SQL scoring only | SQL scoring only | Local chatbot | Skipped |
| **n8n ON + fail** | Error + manual assign | Error notification | Error + manual assign | Local fallback | Silent fail |

### How the Frontend Sends Pre-Filtered Data

When n8n is ON, the frontend **always** runs SQL scoring first, then sends the results to n8n:

```
Single Task (AI Assign / Auto-Assign on Create):
  payload = {
    task_id, mode: "suggest",
    task_context: { ref, queue, priority, field, rule, sla_deadline, ... },
    pre_filtered_candidates: [ { analyst_id, name, sql_score, scores, reasoning, ... } ]
  }

Bulk (Auto-Assign All):
  // Batched into groups of 10 tasks
  payload = {
    mode: "batch_assign",
    tasks: [
      { task_id, ref, queue, priority, ..., pre_filtered_candidates: [...] },
      ...  // up to 10 tasks per batch
    ]
  }
```

This ensures LLM receives compact, pre-computed data — **80% fewer tokens** than querying raw DB.

---

## 12. Production Deployment Checklist

### Before Demo ✅

- [ ] Run embedding SQL setup in Supabase SQL Editor
- [ ] Install n8n (Docker or npm)
- [ ] Add OpenAI + Postgres credentials in n8n
- [ ] Create Workflow 1 (AI Assignment) — minimum viable
- [ ] Create Workflow 3 (Chatbot) — minimum viable
- [ ] Update webhook URLs in `lseg-app.js`
- [ ] Toggle n8n ON in AI Settings
- [ ] Test: click AI Assign → see LLM suggestions
- [ ] Test: chat "SLA breaches" → see agentic response

### For Production 🚀

- [ ] Create Workflow 2 (Batch Auto-Assign) for scale
- [ ] Create Workflow 4 (Embedding Generator)
- [ ] Create Workflow 5 (SLA Monitor cron)
- [ ] Run embedding backfill for existing tasks
- [ ] Switch from `webhook-test` to `webhook` (activate workflows)
- [ ] Add authentication to webhooks (API key header)
- [ ] Set up n8n error handling and retry logic
- [ ] Configure CORS for production domain
- [ ] Set up monitoring / alerting for n8n health
- [ ] Rate-limit OpenAI calls (Tier 1 SQL handles 95%)

---

## 13. Cost Estimation

### OpenAI API Costs at Scale (Efficient Agentic LLM)

| Component | Model | Calls/Day | Cost/Call | Daily Cost | Monthly |
|-----------|-------|-----------|-----------|------------|---------|
| AI Assign (interactive click) | GPT-4o | ~50 clicks | ~$0.03 | $1.50 | $45 |
| Auto-Assign on task creation | GPT-4o-mini | ~100 (auto) | ~$0.01 | $1.00 | $30 |
| Batch Auto-Assign All | GPT-4o-mini | ~15 batches (150 tasks ÷ 10/batch) | ~$0.01 | $0.15 | $4.50 |
| Chatbot | GPT-4o-mini | ~100 questions | ~$0.005 | $0.50 | $15 |
| Embeddings | text-embedding-3-small | 300 tasks | ~$0.00001 | $0.003 | $0.09 |
| SLA Monitor | SQL + LLM alert | 48 (every 30m) | ~$0.001 | $0.05 | $1.50 |
| **TOTAL** | | | | **~$3.20/day** | **~$96/month** |

### Why This Is Efficient (LLM Everywhere, But Smart)

| Efficiency Technique | Savings |
|---------------------|---------|
| **SQL pre-filtering** | LLM receives 5 candidates, not 50 analysts → **80% fewer tokens** |
| **Batch grouping** (10 tasks/call) | 150 tasks = 15 LLM calls, not 150 → **10x fewer API calls** |
| **GPT-4o-mini for batch/auto** | 10x cheaper than GPT-4o, still intelligent |
| **GPT-4o only for interactive** | User sees high-quality reasoning when they click |
| **Pre-computed scores in payload** | LLM doesn't query DB → fewer tokens, faster response |
| **Async embeddings** | Fire-and-forget, doesn't block UI |

### Cost Comparison: Naive vs Efficient

| Approach | 300 tasks/day | Monthly Cost |
|----------|--------------|-------------|
| **Naive**: 1 GPT-4o call per task (full context) | 300 calls × $0.05 | **$450/month** |
| **Efficient**: SQL pre-filter + batched GPT-4o-mini | 30 batch calls × $0.01 + 50 interactive × $0.03 | **~$96/month** |
| **Savings** | | **~78% cheaper** |

---

## 14. Demo Script

### Demo Flow (10 minutes)

**1. Show the Dashboard** (1 min)
- Point out task queue, SLA indicators, team view
- "200-300 tasks per day, each with multiple failed outcomes"

**2. Show AI Settings Toggle** (30 sec)
- Open AI Settings → show n8n toggle
- "We can switch between local scoring and n8n AI Agent"

**3. Demo AI Assign (n8n ON)** (2 min)
- Click "AI Assign" on a task
- Show: loading state → n8n call → AI suggestions with reasoning
- "The AI Agent receives eligible analysts, checks speciality match, leave schedules, workload, and ranks the best analysts with reasoning"
- Point out: scores, reasoning, strengths, risks, estimated resolution time

**4. Demo Chatbot** (2 min)
- Ask: "SLA breaches today" → show agentic response
- Ask: "Who is available in Instruments queue?" → show tool selection
- Ask: "Give me an operations summary" → show comprehensive stats
- "The chatbot is agentic — it autonomously decides which database queries to run"

**5. Show Architecture Slide** (1 min)
- Reference the architecture diagram
- Explain: "Every assignment is AI-powered. SQL pre-filters candidates in <10ms, then LLM re-ranks with intelligent reasoning."
- "Batch assignments process 10 tasks per LLM call — cross-task load balancing that SQL can't do."

**6. Explain Embeddings** (1 min)
- "When a task is created, we generate a vector embedding of its description"
- "This enables: 'Find tasks similar to this one' and 'Who resolved similar tasks fastest?'"
- "Uses pgvector in Supabase — same database, no extra infrastructure"

**7. Show Scalability Story** (1 min)
- "300 tasks/day: SQL pre-filters in milliseconds, LLM adds intelligence efficiently"
- "Batch mode: 10 tasks per LLM call. 300 tasks = 30 LLM calls, not 300"
- "Total cost: ~$96/month — 78% cheaper than naive 1-call-per-task approach"

**8. Show Local Fallback** (30 sec)
- Toggle n8n OFF
- Click AI Assign → show SQL scoring still works
- "Zero dependency on external services — always operational"

**9. Q&A** (2 min)

### Key Talking Points

1. **"Agentic, not scripted"** — AI decides how to rank, not hardcoded rules. LLM does cross-task load balancing, edge case detection, nuanced reasoning.
2. **"LLM everywhere, but efficient"** — SQL pre-filters (free) → LLM re-ranks (cheap). 80% fewer tokens. 10 tasks per batch call.
3. **"Structured RAG"** — We query SQL, not chunk PDFs. Much more accurate.
4. **"Embeddings for memory"** — System learns from past resolutions. "Who resolved similar tasks fastest?"
5. **"Graceful degradation"** — Works without n8n (SQL scoring), works without OpenAI (local fallback)
6. **"~$96/month"** — Full Agentic AI for 300 tasks/day. 78% cheaper than naive approach ($450/month).
