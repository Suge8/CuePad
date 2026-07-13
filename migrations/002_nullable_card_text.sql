CREATE TABLE card_tags_copy AS SELECT card_id, tag_id, created_at FROM card_tags;

DROP TABLE card_tags;

CREATE TABLE cards_new (
  id INTEGER PRIMARY KEY,
  project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL,
  title TEXT,
  body TEXT,
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

INSERT INTO cards_new (
  id,
  project_id,
  title,
  body,
  sort_order,
  is_favorite,
  deleted_at,
  delete_batch_id,
  delete_source,
  delete_source_id,
  created_at,
  updated_at
)
SELECT
  id,
  project_id,
  title,
  body,
  sort_order,
  is_favorite,
  deleted_at,
  delete_batch_id,
  delete_source,
  delete_source_id,
  created_at,
  updated_at
FROM cards;

DROP TABLE cards;
ALTER TABLE cards_new RENAME TO cards;

CREATE TABLE card_tags (
  card_id INTEGER NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
  tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (card_id, tag_id)
);

INSERT INTO card_tags (card_id, tag_id, created_at)
SELECT card_id, tag_id, created_at FROM card_tags_copy;

DROP TABLE card_tags_copy;

CREATE INDEX idx_cards_project_sort ON cards(project_id, deleted_at, sort_order, id);
CREATE INDEX idx_cards_deleted ON cards(deleted_at, updated_at);
CREATE INDEX idx_cards_favorite ON cards(is_favorite, deleted_at, updated_at);
CREATE INDEX idx_card_tags_tag ON card_tags(tag_id, card_id);
