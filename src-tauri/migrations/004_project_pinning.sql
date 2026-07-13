DROP INDEX idx_projects_favorite;
ALTER TABLE projects RENAME COLUMN is_favorite TO is_pinned;
CREATE INDEX idx_projects_pinned ON projects(is_pinned, deleted_at, sort_order);
