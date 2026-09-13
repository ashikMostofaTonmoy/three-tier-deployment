-- Tier 3 schema. One table: every weather query the backend served, so the
-- frontend's "Recent searches" panel has real data to show.
CREATE TABLE IF NOT EXISTS search_history (
    id          SERIAL PRIMARY KEY,
    city        TEXT,
    latitude    NUMERIC(9, 5) NOT NULL,
    longitude   NUMERIC(9, 5) NOT NULL,
    temperature NUMERIC(5, 2),
    queried_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS search_history_queried_at_idx
    ON search_history (queried_at DESC);
