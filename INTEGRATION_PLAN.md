# LSEG Data Operations Hub — Full Integration Plan
## UI ↔ Supabase ↔ n8n End-to-End Architecture
### Updated with Actual Supabase Schema (Feb 2026)

---

## 1. ARCHITECTURE OVERVIEW

```
┌──────────────┐       ┌──────────────────┐       ┌──────────────┐
│   Frontend   │──────▶│    Supabase      │◀──────│     n8n      │
│  (HTML/JS)   │       │  (PostgreSQL +   │       │  (AI Auto-   │
│              │◀──────│   Realtime +     │──────▶│  Assignment  │
│              │       │   pgvector)      │       │  Workflows)  │
└──────────────┘       └──────────────────┘       └──────────────┘
       │                       │                         │
       │  supabase-js client   │  DB Triggers /          │  Webhook +
       │  (CRUD + Realtime)    │  Webhook Notify          │  Supabase API
       │                       │                         │  + LLM (GPT-4o)
```

**Data Flow:**
1. UI reads/writes to Supabase via `supabase-js` client
2. Supabase DB triggers (or Realtime) notify n8n when tasks are created/updated
3. n8n runs the AI scoring workflow → writes assignment back to Supabase
4. UI receives real-time updates via Supabase Realtime subscriptions

---

## 2. ACTUAL SUPABASE SCHEMA

### 2.1 `analysts`
| Column             | Type        | Nullable | Notes                                         |
|--------------------|-------------|----------|-----------------------------------------------|
| id                 | text (PK)   | NO       | e.g. 'a1', 'analyst-js', etc.                |
| username           | text        | NO       |                                               |
| email              | text        | YES      |                                               |
| full_name          | text        | NO       |                                               |
| country            | text        | YES      |                                               |
| domain_ids         | text[]      | YES      | Array of domain IDs analyst covers            |
| queue_ids          | text[]      | NO       | Array of queue IDs analyst belongs to         |
| speciality         | text[]      | YES      | Skills: ['ISIN', 'CFI Code', 'Bonds', ...]   |
| experience_yrs     | int         | YES      |                                               |
| working_hrs_from   | time        | YES      | Working hours start (local time)              |
| working_hrs_to     | time        | YES      | Working hours end (local time)                |
| timezone           | text        | YES      | e.g. 'Europe/London'                          |
| active_tasks       | int         | YES      | Current active task count                     |
| tasks_resolved     | int         | YES      | Lifetime resolved count                       |
| avg_resolution_mins| int         | YES      | Overall average resolution time               |
| status             | text        | YES      | 'active', 'inactive', 'on_leave'              |
| notes              | text        | YES      |                                               |
| created_at         | timestamptz | YES      |                                               |
| updated_at         | timestamptz | YES      |                                               |

**Design notes:**
- Uses text[] arrays for `queue_ids` and `speciality` instead of junction tables (simpler)
- Workload measured by `active_tasks` relative to team average (no hard caps)
- Working hours + timezone enables global team scheduling awareness

### 2.2 `analyst_leaves`
| Column     | Type        | Nullable | Notes                                     |
|------------|-------------|----------|-------------------------------------------|
| id         | int (PK)    | NO       |                                           |
| analyst_id | text (FK)   | NO       | → analysts.id                             |
| date_from  | date        | NO       | Leave start date                          |
| date_to    | date        | NO       | Leave end date                            |
| type       | text        | NO       | 'Annual Leave', 'Sick Leave', 'Conference', 'Training' |
| note       | text        | YES      |                                           |
| approved   | boolean     | YES      |                                           |
| created_at | timestamptz | YES      |                                           |

**Design notes:**
- Date range model (date_from → date_to) — more efficient than per-day rows
- n8n checks: `CURRENT_DATE BETWEEN date_from AND date_to` to determine availability

### 2.3 `tasks`
| Column          | Type           | Nullable | Notes                                      |
|-----------------|----------------|----------|--------------------------------------------|
| id              | text (PK)      | NO       |                                            |
| ref             | text           | NO       | 'TSK-001', etc.                            |
| description     | text           | YES      |                                            |
| queue_id        | text (FK)      | NO       | → queues.id                                |
| domain_id       | text (FK)      | YES      | → domains.id                               |
| priority        | text           | NO       | 'Critical', 'High', 'Medium', 'Low'       |
| field           | text           | YES      | Validated field: 'ISIN', 'CFI Code', etc.  |
| rule            | text           | YES      | Validation rule name                       |
| suite_id        | text           | YES      | GX suite reference                         |
| status          | text           | NO       | 'New', 'Active', 'Blocked', 'Resolved', 'Closed' |
| sla_deadline    | timestamptz    | YES      | Hard SLA deadline                          |
| assignee_id     | text (FK)      | YES      | → analysts.id                              |
| assigned_by     | text           | YES      | 'AI_AUTO', 'AI_SUGGESTED', 'MANUAL'       |
| ai_confidence   | int            | YES      | AI assignment confidence score (0-100)     |
| outcomes_count  | int            | YES      | Total failed outcomes                      |
| open_count      | int            | YES      | Remaining open outcomes                    |
| source_system   | text           | YES      | 'Bloomberg', 'Refinitiv', etc.             |
| batch_ref       | text           | YES      | Batch reference                            |
| created_at      | timestamptz    | YES      |                                            |
| updated_at      | timestamptz    | YES      |                                            |
| resolved_at     | timestamptz    | YES      |                                            |
| task_embedding   | vector        | YES      | pgvector embedding for similarity search   |

**Design notes:**
- `ai_confidence` stores the top score directly on the task (avoids extra query)
- `task_embedding` enables pgvector similarity search against resolution_history

### 2.4 `failed_outcomes`
| Column           | Type        | Nullable | Notes                                    |
|------------------|-------------|----------|------------------------------------------|
| id               | int (PK)    | NO       |                                          |
| task_id          | text (FK)   | NO       | → tasks.id                               |
| record_id        | text        | NO       | Source record identifier                 |
| validated_field  | text        | NO       | 'ISIN', 'CFI Code', etc.                |
| failed_value     | text        | YES      | The actual failing value                 |
| rule_description | text        | NO       | The validation rule description          |
| validation_stage | text        | NO       | 'Normalized', 'Raw', etc.               |
| table_name       | text        | NO       | Source table                             |
| suite_id         | text        | YES      | GX suite reference                       |
| severity         | text        | NO       | 'Stop Field', 'Warning'                 |
| expected_pattern | text        | YES      | Regex/expected value                     |
| domain_id        | text        | YES      | → domains.id                             |
| source_system    | text        | YES      |                                          |
| batch_ref        | text        | YES      |                                          |
| status           | text        | NO       | 'In Task', 'Resolved'                   |
| resolution_note  | text        | YES      | How it was resolved                      |
| resolved_by      | text        | YES      | → analysts.id                            |
| resolved_at      | timestamptz | YES      |                                          |
| created_at       | timestamptz | YES      |                                          |

**Design notes:**
- Richer than prototype: includes `failed_value`, `expected_pattern`, `table_name`, `source_system`
- `resolved_by` tracks which analyst actually fixed the outcome

### 2.5 `queues` (lookup)
| Column      | Type    | Nullable | Notes                          |
|-------------|---------|----------|--------------------------------|
| id          | text PK | NO       | e.g. 'instruments'             |
| name        | text    | NO       | 'Instruments'                  |
| description | text    | YES      |                                |
| active      | boolean | YES      |                                |

### 2.6 `domains` (lookup)
| Column      | Type    | Nullable | Notes                          |
|-------------|---------|----------|--------------------------------|
| id          | text PK | NO       | e.g. 'ciqm'                   |
| name        | text    | NO       | 'CIQM'                        |
| description | text    | YES      |                                |
| active      | boolean | YES      |                                |

### 2.7 `resolution_history` (for pgvector / AI scoring)
| Column            | Type        | Nullable | Notes                                    |
|-------------------|-------------|----------|------------------------------------------|
| id                | int (PK)    | NO       |                                          |
| task_id           | text        | YES      | → tasks.id                               |
| analyst_id        | text        | YES      | → analysts.id                            |
| queue_id          | text        | YES      | → queues.id                              |
| field             | text        | YES      | 'ISIN', 'CFI Code', etc.                |
| rule              | text        | YES      | Validation rule                          |
| resolution_mins   | int         | YES      | How long it took to resolve              |
| outcome_status    | text        | YES      | Final status                             |
| outcomes_fixed    | int         | YES      | Number of outcomes resolved              |
| notes             | text        | YES      |                                          |
| resolved_at       | timestamptz | YES      |                                          |
| outcome_embedding | vector      | YES      | pgvector embedding for similarity search |

**Design notes:**
- This is the key table for AI scoring — `outcome_embedding` enables n8n to find
  similar past resolutions and score analysts on historical performance per field/rule

---

## 3. SCHEMA GAPS — SUGGESTED ADDITIONS

### 3.1 `ai_assignment_scores` (NEW TABLE — Recommended)
Stores the full ranked AI suggestions per task so the UI can display all 3 candidates.

```sql
CREATE TABLE ai_assignment_scores (
  id          serial PRIMARY KEY,
  task_id     text NOT NULL REFERENCES tasks(id),
  analyst_id  text NOT NULL REFERENCES analysts(id),
  rank        int NOT NULL,
  overall_score   int NOT NULL,       -- 0-100
  availability    int,                -- component score
  workload        int,
  queue_match     int,
  past_performance int,
  sla_fit         int,
  experience      int,
  reasoning       text,               -- AI-generated explanation
  strengths       text[],
  risks           text[],
  est_resolution_min int,
  selected        boolean DEFAULT false,
  created_at      timestamptz DEFAULT now()
);
CREATE INDEX idx_ai_scores_task ON ai_assignment_scores(task_id);
```

**Why needed:** Currently `tasks.ai_confidence` only stores the winning score. This table stores all ranked candidates so the UI can show the 3-card suggestion panel.

### 3.2 `resolution_guides` (NEW TABLE — Recommended)
Knowledge base for resolution step-by-step guides.

```sql
CREATE TABLE resolution_guides (
  id      serial PRIMARY KEY,
  field   text NOT NULL,         -- 'ISIN', 'CFI Code', 'Effective To/From'
  rule    text NOT NULL,         -- validation rule name
  title   text NOT NULL,
  steps   text[] NOT NULL,       -- ordered step instructions
  active  boolean DEFAULT true,
  UNIQUE(field, rule)
);
```

### 3.3 `config` (NEW TABLE — Optional)
App-level config for AI auto-assign toggles, scoring weights, etc.

```sql
CREATE TABLE config (
  key     text PRIMARY KEY,
  value   jsonb NOT NULL,
  updated_at timestamptz DEFAULT now()
);

INSERT INTO config VALUES
  ('auto_assign',   '{"enabled": false}'::jsonb, now()),
  ('show_notif',    '{"enabled": true}'::jsonb,  now()),
  ('ingest_auto',   '{"enabled": false}'::jsonb, now()),
  ('scoring_weights', '{"availability":25,"workload":20,"queue_match":20,"past_performance":20,"sla_fit":10,"experience":5}'::jsonb, now());
```

---

## 4. PROTOTYPE → SUPABASE FIELD MAPPING

### Tasks
| Prototype (JS)    | Supabase Column     | Notes                           |
|-------------------|---------------------|---------------------------------|
| `t.id`            | `tasks.id`          | text PK                        |
| `t.ref`           | `tasks.ref`         | 'TSK-001'                      |
| `t.desc`          | `tasks.description` |                                 |
| `t.priority`      | `tasks.priority`    |                                 |
| `t.queue`         | `tasks.queue_id`    | Now references queues.id        |
| `t.status`        | `tasks.status`      |                                 |
| `t.domain`        | `tasks.domain_id`   | Now references domains.id       |
| `t.assignee`      | `tasks.assignee_id` |                                 |
| `t.assignedBy`    | `tasks.assigned_by` |                                 |
| `t.sla`           | `tasks.sla_deadline` |                                |
| `t.due`           | *(removed — derive from sla_deadline)* |              |
| `t.outcomes`      | `tasks.outcomes_count` |                              |
| `t.open`          | `tasks.open_count`  |                                 |
| `t.field`         | `tasks.field`       |                                 |
| `t.rule`          | `tasks.rule`        |                                 |
| `t.aiScore.score` | `tasks.ai_confidence` | Top score stored on task      |
| `t.aiScore.*`     | `ai_assignment_scores.*` | Full details in new table |
| `t.created`       | `tasks.created_at`  |                                 |

### Analysts
| Prototype (JS)      | Supabase Column          | Notes                      |
|----------------------|--------------------------|----------------------------|
| `a.id`              | `analysts.id`            |                            |
| `a.name`            | `analysts.full_name`     |                            |
| `a.initials`        | *(derive in UI from full_name)* |                     |
| `a.queues[]`        | `analysts.queue_ids[]`   | Array of queue IDs         |
| `a.skills[]`        | `analysts.speciality[]`  |                            |
| `a.active`          | `analysts.active_tasks`  | Current workload           |
| `a.exp`             | `analysts.experience_yrs`|                            |
| `AVAIL[id]`         | `analyst_leaves` (date range query) |                  |
| `AVAIL_NOTES[id]`   | `analyst_leaves.type` + `.note` |                       |
| `getHistETA(id,fld)` | `resolution_history` (AVG query) |                    |

---

## 5. n8n AUTO-ASSIGNMENT WORKFLOW (Matched to Real Schema)

### 5.1 Workflow Diagram

```
┌─────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  Webhook     │────▶│ Fetch Task   │────▶│ Fetch Queue  │────▶│ Fetch Leaves │
│  Trigger     │     │ + Outcomes   │     │ Analysts     │     │ & History    │
│              │     │ (Supabase)   │     │ (Supabase)   │     │ (Supabase)   │
└─────────────┘     └──────────────┘     └──────────────┘     └──────────────┘
                                                                      │
                                                                      ▼
┌─────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  Update UI   │◀───│ Update Task  │◀───│ Store Scores │◀───│ LLM Scoring  │
│  (Realtime)  │     │ (Supabase)   │     │ (Supabase)   │     │ (GPT-4o)     │
└─────────────┘     └──────────────┘     └──────────────┘     └──────────────┘
```

### 5.2 n8n Nodes (Step-by-Step)

**Node 1 — Webhook Trigger**
- Type: `Webhook`
- URL: `POST /webhook/ai-assign`
- Input: `{ "task_id": "TSK-001", "mode": "suggest" | "auto" }`

**Node 2 — Fetch Task + Failed Outcomes**
- Type: `Supabase` node (Select)
```sql
-- Task
SELECT t.*, q.name as queue_name, d.name as domain_name
FROM tasks t
LEFT JOIN queues q ON q.id = t.queue_id
LEFT JOIN domains d ON d.id = t.domain_id
WHERE t.id = '{{ $json.task_id }}';

-- Outcomes
SELECT * FROM failed_outcomes WHERE task_id = '{{ $json.task_id }}';
```

**Node 3 — Fetch Eligible Analysts**
- Type: `Supabase` node (Select)
```sql
SELECT *
FROM analysts
WHERE queue_ids @> ARRAY['{{ task.queue_id }}']::text[]
  AND status = 'active'
;
```
- The `@>` operator checks if `queue_ids` array contains the task's queue

**Node 4 — Fetch Analyst Leaves**
- Type: `Supabase` node (Select)
```sql
SELECT analyst_id, date_from, date_to, type, note
FROM analyst_leaves
WHERE analyst_id = ANY({{ eligible_analyst_ids }})
  AND approved = true
  AND date_to >= CURRENT_DATE
  AND date_from <= CURRENT_DATE + INTERVAL '5 days';
```
- n8n logic: if `CURRENT_DATE BETWEEN date_from AND date_to` → analyst is on leave today

**Node 5 — Fetch Resolution History (Speciality Check)**
- Type: `Supabase` node (Select)
```sql
SELECT analyst_id,
       field,
       rule,
       COUNT(*) as tasks_done,
       AVG(resolution_mins) as avg_mins,
       SUM(outcomes_fixed) as total_fixed
FROM resolution_history
WHERE analyst_id = ANY({{ eligible_analyst_ids }})
  AND field = '{{ task.field }}'
GROUP BY analyst_id, field, rule;
```

**Node 5b — pgvector Similarity Search (Optional, powerful)**
- Type: `Supabase` node (RPC call or raw SQL)
```sql
SELECT analyst_id, resolution_mins, notes,
       1 - (outcome_embedding <=> '{{ task.task_embedding }}') as similarity
FROM resolution_history
WHERE outcome_embedding IS NOT NULL
ORDER BY outcome_embedding <=> '{{ task.task_embedding }}'
LIMIT 10;
```
- Finds the 10 most similar past resolutions and which analysts solved them

**Node 6 — AI Scoring (LLM Call)**
- Type: `OpenAI` node (GPT-4o / GPT-4o-mini)
- System Prompt:
```
You are the LSEG Data Operations intelligent task assignment engine.
Given a task and a list of eligible analysts with their profiles, availability,
workload, and speciality data, score each analyst on these dimensions:

1. Availability (20%): Is analyst on leave? On-leave = scored lower (25), not excluded.
2. Workload (20%): active_tasks relative to team average. Fewer = higher score.
3. Speciality (20%): Does analyst's speciality match the task field? (e.g., ISIN, CFI Code)
4. Working Hours (15%): Is analyst currently in their working hours based on timezone?
   - in_working_hours=true → 100, false → 20. Not set → 70 (neutral).
5. Experience (13%): More years = higher score.
6. SLA Fit (12%): Can analyst realistically resolve before sla_deadline?
   - Compare avg_resolution_mins to time remaining

Return ONLY valid JSON array ranked by overall_score descending:
[{
  "rank": 1,
  "analyst_id": "a1",
  "overall_score": 91,
  "scores": {
    "Availability": 100, "Workload": 70, "Speciality": 95,
    "Working Hours": 100, "Experience": 85, "SLA Fit": 90
  },
  "reasoning": "...",
  "strengths": ["ISIN Specialist", "Fastest Resolver"],
  "risks": [],
  "est_resolution_min": 42
}]
```
- User Prompt: Concatenated task JSON + analyst profiles + leaves + history data

**Node 7 — Store AI Scores**
- Type: `Supabase` node (Insert, loop over results)
```sql
INSERT INTO ai_assignment_scores
  (task_id, analyst_id, rank, overall_score, scores,
   reasoning, strengths, risks, est_resolution_min)
VALUES (...);
```

**Node 8 — Check Mode (Auto vs Suggest)**
- Type: `IF` node
- If `mode === 'auto'` → proceed to assign
- If `mode === 'suggest'` → stop here (UI shows suggestions via Realtime)

**Node 9 — Auto-Assign Top Analyst**
- Type: `Supabase` node (Update)
```sql
-- Assign task
UPDATE tasks
SET assignee_id = '{{ top.analyst_id }}',
    assigned_by = 'AI_AUTO',
    ai_confidence = {{ top.overall_score }},
    status = 'Active',
    updated_at = now()
WHERE id = '{{ task_id }}';

-- Increment analyst workload
UPDATE analysts
SET active_tasks = active_tasks + 1,
    updated_at = now()
WHERE id = '{{ top.analyst_id }}';

-- Mark score as selected
UPDATE ai_assignment_scores
SET selected = true
WHERE task_id = '{{ task_id }}' AND analyst_id = '{{ top.analyst_id }}';
```

**Node 10 — (Realtime handles UI update automatically)**

### 5.3 Additional n8n Workflows

| Workflow                  | Trigger                                | Action                                              |
|---------------------------|----------------------------------------|-----------------------------------------------------|
| **Bulk Auto-Assign**      | Webhook: `POST /webhook/bulk-assign`   | Query all `status='New' AND assignee_id IS NULL` tasks, loop through AI assign workflow for each |
| **SLA Breach Monitor**    | Cron: every 15 min                     | Query `tasks WHERE sla_deadline < now() + interval '2h' AND status NOT IN ('Resolved','Closed')`, send alerts |
| **Ingest + Create Task**  | Webhook: `POST /webhook/ingest`        | Insert failed_outcomes → create task → trigger AI assign |
| **Task Resolved**         | Supabase trigger: `UPDATE tasks SET status='Resolved'` | Decrement `analysts.active_tasks`, insert into `resolution_history` |
| **Embed Task (pgvector)** | After task creation                    | Generate embedding from task description + field + rule, store in `tasks.task_embedding` |

---

## 6. UI ↔ SUPABASE INTEGRATION

### 6.1 Add Supabase JS Client to HTML

```html
<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
<script>
  const SUPABASE_URL = 'https://YOUR_PROJECT.supabase.co';
  const SUPABASE_ANON_KEY = 'YOUR_ANON_KEY';
  const sb = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
</script>
```

### 6.2 Replace Hardcoded Data with Supabase Queries

| Prototype Variable | Supabase Query                                                    |
|--------------------|-------------------------------------------------------------------|
| `ANALYSTS`         | `sb.from('analysts').select('*').eq('status','active')`           |
| `AVAIL` / `AVAIL_NOTES` | `sb.from('analyst_leaves').select('*').gte('date_to', today)` |
| `TASKS`            | `sb.from('tasks').select('*, queues(name), domains(name)')`       |
| Failed outcomes    | `sb.from('failed_outcomes').select('*').eq('task_id', id)`        |
| `AI_SCORES`        | `sb.from('ai_assignment_scores').select('*').eq('task_id', id)`   |
| `KB`               | `sb.from('resolution_guides').select('*')` *(after creating table)* |
| `getHistETA()`     | `sb.from('resolution_history').select('*').eq('analyst_id',id).eq('field',f)` |
| `CFG`              | `sb.from('config').select('*')` *(after creating table)*         |

### 6.3 Key Function Refactors

```javascript
// Load all data on page init
async function loadData() {
  const [analysts, tasks, leaves, queues, domains] = await Promise.all([
    sb.from('analysts').select('*').eq('status', 'active'),
    sb.from('tasks').select('*, queues(name), domains(name)').order('created_at', {ascending: false}),
    sb.from('analyst_leaves').select('*').gte('date_to', new Date().toISOString().split('T')[0]),
    sb.from('queues').select('*').eq('active', true),
    sb.from('domains').select('*').eq('active', true)
  ]);
  ANALYSTS = analysts.data;
  TASKS = tasks.data;
  LEAVES = leaves.data;
  QUEUES = queues.data;
  DOMAINS = domains.data;
  renderTasks();
}

// Check if analyst is on leave today
function isOnLeaveToday(analystId) {
  const today = new Date().toISOString().split('T')[0];
  return LEAVES.some(l => l.analyst_id === analystId
    && l.approved !== false
    && l.date_from <= today && l.date_to >= today);
}

// AI Assign — calls n8n webhook
async function openAISuggest(taskId) {
  showLoadingSpinner();
  const resp = await fetch('https://YOUR_N8N_URL/webhook/ai-assign', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ task_id: taskId, mode: 'suggest' })
  });
  // Scores will arrive via Supabase Realtime → render suggestions
}

// Bulk Auto-Assign
async function bulkAutoAssign() {
  const resp = await fetch('https://YOUR_N8N_URL/webhook/bulk-assign', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ mode: 'auto' })
  });
  notify('AI Auto-Assignment', 'Processing...', 'info');
}
```

### 6.4 Realtime Subscriptions (Live Updates)

```javascript
// Live task updates (assignment, status changes)
sb.channel('tasks-realtime')
  .on('postgres_changes',
    { event: '*', schema: 'public', table: 'tasks' },
    (payload) => {
      const idx = TASKS.findIndex(t => t.id === payload.new.id);
      if (payload.eventType === 'INSERT') TASKS.unshift(payload.new);
      else if (idx > -1) TASKS[idx] = { ...TASKS[idx], ...payload.new };
      renderTasks();
    })
  .subscribe();

// Live AI score results (n8n writes scores → UI shows suggestions)
sb.channel('ai-scores-realtime')
  .on('postgres_changes',
    { event: 'INSERT', schema: 'public', table: 'ai_assignment_scores' },
    (payload) => {
      if (payload.new.task_id === _aiTaskId) {
        // Collect all scores for this task, render suggestion modal
        loadAIScores(payload.new.task_id);
      }
    })
  .subscribe();
```

---

## 7. API ENDPOINTS SUMMARY

### UI → Supabase (Direct via supabase-js)
| Action                 | Method                                                  |
|------------------------|---------------------------------------------------------|
| Load tasks             | `sb.from('tasks').select('*, queues(name), domains(name)')` |
| Load analysts          | `sb.from('analysts').select('*')`                       |
| Load leaves            | `sb.from('analyst_leaves').select('*')`                 |
| Create task            | `sb.from('tasks').insert({...})`                        |
| Resolve outcome        | `sb.from('failed_outcomes').update({status:'Resolved', resolved_by:..., resolved_at:now()})` |
| Update task status     | `sb.from('tasks').update({status:..., updated_at:now()})` |
| Manual assign          | `sb.from('tasks').update({assignee_id:..., assigned_by:'MANUAL'})` |
| Fetch AI scores        | `sb.from('ai_assignment_scores').select('*').eq('task_id', id)` |
| Accept AI suggestion   | `sb.from('tasks').update({assignee_id, assigned_by:'AI_SUGGESTED', ai_confidence})` |

### UI → n8n (Webhook Calls)
| Action                      | Webhook                                      | Payload                              |
|-----------------------------|----------------------------------------------|--------------------------------------|
| AI Assign (single task)     | `POST /webhook/ai-assign`                   | `{ task_id, mode: 'suggest'|'auto' }` |
| Bulk Auto-Assign            | `POST /webhook/bulk-assign`                 | `{ mode: 'auto' }`                  |
| Ingest + Create + Assign    | `POST /webhook/ingest`                      | `{ outcomes: [...], task: {...} }`   |

### n8n → Supabase
| Action                      | Operation                                     |
|-----------------------------|-----------------------------------------------|
| Read task + outcomes        | SELECT from tasks + failed_outcomes            |
| Read eligible analysts      | SELECT from analysts WHERE queue_ids @> ARRAY  |
| Read leaves                 | SELECT from analyst_leaves (date range check)  |
| Read resolution history     | SELECT + pgvector similarity from resolution_history |
| Write AI scores             | INSERT into ai_assignment_scores               |
| Assign task                 | UPDATE tasks + UPDATE analysts.active_tasks    |

---

## 8. IMPLEMENTATION ORDER

### Phase 1 — Supabase Setup (1-2 days)
1. ✅ Core tables created (analysts, analyst_leaves, tasks, failed_outcomes, queues, domains, resolution_history)
2. **Create** `ai_assignment_scores` table (SQL above)
3. **Create** `resolution_guides` table + seed KB data
4. **Create** `config` table + seed defaults
5. Seed sample data matching the prototype (analysts, tasks, outcomes)
6. Enable Realtime on `tasks` and `ai_assignment_scores`
7. Set up RLS policies (or disable for POC)

### Phase 2 — n8n Workflows (2-3 days)
1. Build single-task AI assignment workflow (Nodes 1-10)
2. Test with manual webhook (`curl POST /webhook/ai-assign`)
3. Add bulk auto-assign workflow
4. Add ingest → create → assign workflow
5. Add SLA breach monitor (cron every 15 min)
6. Add task-resolved → update analyst workload workflow

### Phase 3 — UI Refactor (2-3 days)
1. Add Supabase JS client to HTML
2. Replace hardcoded data arrays with async Supabase queries
3. Replace assignment functions with n8n webhook calls
4. Add Realtime subscriptions for live updates
5. Add loading states (spinners while n8n processes)
6. Test full end-to-end flow

### Phase 4 — Polish (1-2 days)
1. Error handling (network failures, n8n timeouts)
2. Chatbot: wire to Supabase queries or n8n AI
3. pgvector: generate embeddings for tasks + resolution history
4. Auth (Supabase Auth for analyst login — optional for POC)

---

## 9. KEY CONSIDERATIONS

- **Workload**: Scored relative to team average active_tasks. No hard caps — the AI Agent reasons about workload contextually.
- **Working Hours (6th scoring dimension)**: Both frontend and AI Agent check if the analyst is currently within their `working_hrs_from` → `working_hrs_to` (using their timezone). In hours = 100, outside = 20, not set = 70 (neutral). Weight: 15%.
- **Leave Date Ranges**: Unlike the prototype's per-day booleans, your `analyst_leaves` uses date ranges. n8n checks `CURRENT_DATE BETWEEN date_from AND date_to` for leave status.
- **pgvector Embeddings**: Both `tasks.task_embedding` and `resolution_history.outcome_embedding` enable powerful similarity search. n8n should generate embeddings (via OpenAI embeddings API) when creating tasks and use cosine similarity to find past resolutions.
- **SLA Calculation**: Keep `getSLA()` in the UI for real-time countdowns. n8n also computes SLA urgency during scoring.
- **Latency**: n8n LLM scoring takes 3-8 seconds. Show a loading spinner. Supabase Realtime pushes scores to UI when ready.
- **Idempotency**: n8n workflows should check if task is already assigned before processing.
