PRAGMA foreign_keys = ON;

CREATE TABLE projects (
  id INTEGER PRIMARY KEY,
  name TEXT,
  icon TEXT,
  color TEXT NOT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0,
  is_favorite INTEGER NOT NULL DEFAULT 0 CHECK (is_favorite IN (0, 1)),
  deleted_at INTEGER,
  delete_batch_id TEXT,
  delete_source TEXT CHECK (delete_source IS NULL OR delete_source IN ('project', 'card', 'tag')),
  delete_source_id INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  CHECK (
    (deleted_at IS NULL AND delete_batch_id IS NULL AND delete_source IS NULL AND delete_source_id IS NULL)
    OR
    (deleted_at IS NOT NULL AND delete_batch_id IS NOT NULL AND delete_source IS NOT NULL AND delete_source_id IS NOT NULL)
  )
);

CREATE TABLE cards (
  id INTEGER PRIMARY KEY,
  project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL,
  title TEXT NOT NULL DEFAULT '',
  body TEXT NOT NULL DEFAULT '',
  sort_order INTEGER NOT NULL DEFAULT 0,
  is_favorite INTEGER NOT NULL DEFAULT 0 CHECK (is_favorite IN (0, 1)),
  deleted_at INTEGER,
  delete_batch_id TEXT,
  delete_source TEXT CHECK (delete_source IS NULL OR delete_source IN ('project', 'card', 'tag')),
  delete_source_id INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  CHECK (
    (deleted_at IS NULL AND delete_batch_id IS NULL AND delete_source IS NULL AND delete_source_id IS NULL)
    OR
    (deleted_at IS NOT NULL AND delete_batch_id IS NOT NULL AND delete_source IS NOT NULL AND delete_source_id IS NOT NULL)
  )
);

CREATE TABLE tags (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  color TEXT,
  sort_order INTEGER NOT NULL DEFAULT 0,
  deleted_at INTEGER,
  delete_batch_id TEXT,
  delete_source TEXT CHECK (delete_source IS NULL OR delete_source IN ('project', 'card', 'tag')),
  delete_source_id INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  CHECK (
    (deleted_at IS NULL AND delete_batch_id IS NULL AND delete_source IS NULL AND delete_source_id IS NULL)
    OR
    (deleted_at IS NOT NULL AND delete_batch_id IS NOT NULL AND delete_source IS NOT NULL AND delete_source_id IS NOT NULL)
  )
);

CREATE TABLE card_tags (
  card_id INTEGER NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
  tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (card_id, tag_id)
);

CREATE TABLE app_settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE INDEX idx_projects_active_sort ON projects(deleted_at, sort_order, id);
CREATE INDEX idx_projects_favorite ON projects(is_favorite, deleted_at, sort_order);
CREATE INDEX idx_cards_project_sort ON cards(project_id, deleted_at, sort_order, id);
CREATE INDEX idx_cards_deleted ON cards(deleted_at, updated_at);
CREATE INDEX idx_cards_favorite ON cards(is_favorite, deleted_at, updated_at);
CREATE INDEX idx_tags_active_name ON tags(deleted_at, name);
CREATE INDEX idx_card_tags_tag ON card_tags(tag_id, card_id);

INSERT INTO app_settings (key, value, created_at, updated_at)
VALUES
  ('theme', '"system"', CAST(strftime('%s', 'now') AS INTEGER) * 1000, CAST(strftime('%s', 'now') AS INTEGER) * 1000),
  ('globalShortcut', 'null', CAST(strftime('%s', 'now') AS INTEGER) * 1000, CAST(strftime('%s', 'now') AS INTEGER) * 1000)
ON CONFLICT(key) DO NOTHING;
