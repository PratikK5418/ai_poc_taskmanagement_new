-- ============================================================
-- LSEG Data Operations Hub — Supabase Setup
-- Run this in your Supabase SQL Editor
-- ============================================================

-- 1. AI Assignment Scores table
--    Stores ranked AI suggestions per task (top 3 analysts)
CREATE TABLE IF NOT EXISTS ai_assignment_scores (
  id              serial PRIMARY KEY,
  task_id         text NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  analyst_id      text NOT NULL REFERENCES analysts(id) ON DELETE CASCADE,
  rank            int NOT NULL,
  overall_score   int NOT NULL,
  scores          jsonb,
  reasoning       text,
  strengths       text[],
  risks           text[],
  est_resolution_min int,
  selected        boolean DEFAULT false,
  created_at      timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ai_scores_task ON ai_assignment_scores(task_id);
CREATE INDEX IF NOT EXISTS idx_ai_scores_analyst ON ai_assignment_scores(analyst_id);

-- 2. Config table
--    App-level settings for AI assignment behavior
CREATE TABLE IF NOT EXISTS config (
  key         text PRIMARY KEY,
  value       jsonb NOT NULL,
  updated_at  timestamptz DEFAULT now()
);

INSERT INTO config (key, value) VALUES
  ('auto_assign',      '{"enabled": false}'::jsonb),
  ('show_notif',       '{"enabled": true}'::jsonb),
  ('ingest_auto',      '{"enabled": false}'::jsonb),
  ('scoring_weights',  '{"availability":25,"workload":20,"queue_match":20,"past_performance":20,"sla_fit":10,"experience":5}'::jsonb)
ON CONFLICT (key) DO NOTHING;

-- 3. Enable Realtime on key tables
--    This allows the UI to receive live updates via Supabase Realtime
ALTER PUBLICATION supabase_realtime ADD TABLE tasks;
ALTER PUBLICATION supabase_realtime ADD TABLE ai_assignment_scores;
ALTER PUBLICATION supabase_realtime ADD TABLE analysts;
ALTER PUBLICATION supabase_realtime ADD TABLE failed_outcomes;
ALTER PUBLICATION supabase_realtime ADD TABLE analyst_leaves;

-- 3b. Add temp_unavailable_until column to analysts (for "Mark Away" feature)
--     When set and > now(), analyst is temporarily unavailable.
--     When null or <= now(), normal availability rules apply.
ALTER TABLE analysts ADD COLUMN IF NOT EXISTS temp_unavailable_until timestamptz DEFAULT NULL;

-- 4. Helper function: decrement analyst active_tasks on task resolve
CREATE OR REPLACE FUNCTION decrement_active_tasks(p_analyst_id text)
RETURNS void AS $$
BEGIN
  UPDATE analysts
  SET active_tasks = GREATEST(0, COALESCE(active_tasks, 0) - 1),
      updated_at = now()
  WHERE id = p_analyst_id;
END;
$$ LANGUAGE plpgsql;

-- 5. Helper function: increment analyst active_tasks on task assign
CREATE OR REPLACE FUNCTION increment_active_tasks(p_analyst_id text)
RETURNS void AS $$
BEGIN
  UPDATE analysts
  SET active_tasks = COALESCE(active_tasks, 0) + 1,
      updated_at = now()
  WHERE id = p_analyst_id;
END;
$$ LANGUAGE plpgsql;

-- 6. Task Status Log — tracks every status transition for time tracking
--    AI uses this to learn how long each phase takes per analyst
CREATE TABLE IF NOT EXISTS task_status_log (
  id          serial PRIMARY KEY,
  task_id     text NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  from_status text,
  to_status   text NOT NULL,
  changed_by  text,
  changed_at  timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_status_log_task ON task_status_log(task_id);
CREATE INDEX IF NOT EXISTS idx_status_log_analyst ON task_status_log(changed_by);

ALTER PUBLICATION supabase_realtime ADD TABLE task_status_log;

-- 7. Add lifecycle timestamp columns to tasks table (if missing)
--    These track when each status was first reached
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='tasks' AND column_name='activated_at') THEN
    ALTER TABLE tasks ADD COLUMN activated_at timestamptz;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='tasks' AND column_name='blocked_at') THEN
    ALTER TABLE tasks ADD COLUMN blocked_at timestamptz;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='tasks' AND column_name='resolved_at') THEN
    ALTER TABLE tasks ADD COLUMN resolved_at timestamptz;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='tasks' AND column_name='closed_at') THEN
    ALTER TABLE tasks ADD COLUMN closed_at timestamptz;
  END IF;
END $$;

-- 8. Resolution History — tracks how analysts resolved tasks (for AI learning)
--    The AI uses this to estimate resolution time and match analysts to similar tasks
CREATE TABLE IF NOT EXISTS resolution_history (
  id              serial PRIMARY KEY,
  task_id         text NOT NULL,
  analyst_id      text NOT NULL,
  queue_id        text,
  field           text,
  rule            text,
  resolution_mins int,
  outcomes_fixed  int DEFAULT 0,
  resolved_at     timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_res_hist_analyst ON resolution_history(analyst_id);
CREATE INDEX IF NOT EXISTS idx_res_hist_field ON resolution_history(field);
CREATE INDEX IF NOT EXISTS idx_res_hist_task ON resolution_history(task_id);

-- 9. Auto-generate task ref sequence
CREATE SEQUENCE IF NOT EXISTS task_ref_seq START WITH 100;

CREATE OR REPLACE FUNCTION generate_task_ref()
RETURNS text AS $$
BEGIN
  RETURN 'TSK-' || LPAD(nextval('task_ref_seq')::text, 3, '0');
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 9. PRODUCTION AI SETUP — Embeddings, Indexes, Functions
--    Run this section for AI-powered features
-- ============================================================

-- 9a. Enable pgvector extension
CREATE EXTENSION IF NOT EXISTS vector;

-- 9b. Ensure task_embedding column exists (1536 dims for text-embedding-3-small)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name = 'tasks' AND column_name = 'task_embedding'
  ) THEN
    ALTER TABLE tasks ADD COLUMN task_embedding vector(1536);
  END IF;
END $$;

-- 9c. HNSW index for fast vector similarity search (cosine distance)
CREATE INDEX IF NOT EXISTS idx_tasks_embedding_hnsw
  ON tasks USING hnsw (task_embedding vector_cosine_ops)
  WITH (m = 16, ef_construction = 64);

-- 9d. Performance indexes for production-scale queries
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_queue_status ON tasks(queue_id, status);
CREATE INDEX IF NOT EXISTS idx_tasks_assignee ON tasks(assignee_id);
CREATE INDEX IF NOT EXISTS idx_tasks_sla ON tasks(sla_deadline)
  WHERE status NOT IN ('Resolved', 'Closed');
CREATE INDEX IF NOT EXISTS idx_tasks_created ON tasks(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_tasks_unassigned ON tasks(queue_id)
  WHERE assignee_id IS NULL AND status = 'New';
CREATE INDEX IF NOT EXISTS idx_fo_task ON failed_outcomes(task_id);

-- 9e. Function: Find similar past resolved tasks using vector search
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

-- 9f. Function: Get best analysts for similar tasks
--     "Who resolved tasks like this one fastest?"
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

-- 9g. Function: SQL-based scoring fallback (used when n8n is OFF)
--     6 dimensions: Availability 20%, Workload 20%, Speciality 20%, Working Hours 15%, Experience 13%, SLA Fit 12%
--     Prerequisites: same queue + same domain (not scored, just filtered)
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

  -- Team average active tasks for relative workload comparison
  SELECT COALESCE(AVG(a.active_tasks), 1)
  INTO v_avg_active
  FROM analysts a
  WHERE v_queue_id = ANY(a.queue_ids)
    AND (v_domain_id IS NULL OR v_domain_id = ANY(a.domain_ids));

  RETURN QUERY
  SELECT
    a.id as analyst_id,
    a.full_name as analyst_name,
    -- 6 dimensions
    (
      CASE WHEN EXISTS (
        SELECT 1 FROM analyst_leaves al
        WHERE al.analyst_id = a.id
          AND al.date_from <= CURRENT_DATE AND al.date_to >= CURRENT_DATE
      ) THEN 25 ELSE 100 END * 20  -- Availability 20%
      + GREATEST(0, LEAST(100, ROUND((1 - a.active_tasks::float / GREATEST(v_avg_active * 2, 1)) * 100)::int)) * 20  -- Workload 20%
      + CASE WHEN v_field IS NOT NULL AND v_field = ANY(a.speciality) THEN 100 ELSE 40 END * 20  -- Speciality 20%
      + CASE WHEN a.working_hrs_from IS NULL THEN 70
             WHEN CURRENT_TIME BETWEEN a.working_hrs_from AND a.working_hrs_to THEN 100
             ELSE 20 END * 15  -- Working Hours 15%
      + LEAST(100, COALESCE(a.experience_yrs, 0) * 14) * 13  -- Experience 13%
      + CASE WHEN v_sla_deadline < NOW() THEN 100
             WHEN v_sla_deadline < NOW() + INTERVAL '2 hours' THEN 80
             ELSE 60 END * 12  -- SLA Fit 12%
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
    CASE WHEN v_sla_deadline < NOW() THEN 100
         WHEN v_sla_deadline < NOW() + INTERVAL '2 hours' THEN 80
         ELSE 60 END as sla_score,
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

-- 9h. View: Today's operational summary (used by chatbot / dashboard)
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

-- 9i. Add use_n8n config default
INSERT INTO config (key, value) VALUES
  ('use_n8n', '{"enabled": false}'::jsonb)
ON CONFLICT (key) DO NOTHING;
