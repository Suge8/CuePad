CREATE TABLE tasks (
  id INTEGER PRIMARY KEY,
  content TEXT NOT NULL CHECK (length(trim(content)) > 0),
  project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  completed_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE INDEX idx_tasks_active_sort ON tasks(sort_order, id) WHERE completed_at IS NULL;
CREATE INDEX idx_tasks_project ON tasks(project_id);
