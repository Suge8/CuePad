ALTER TABLE cards ADD COLUMN numbering TEXT NOT NULL DEFAULT 'none'
  CHECK (numbering IN ('none', 'decimal', 'alpha', 'cjk'));
