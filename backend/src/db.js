// The ONE place the backend talks to Postgres (Tier 3).
//
// A Pool, not a single Client: each incoming request borrows a connection,
// uses it, and gives it back — so many requests can be handled concurrently
// without each one paying the cost of a fresh TCP+auth handshake to Postgres.
import pg from 'pg';
import { logger } from './logger.js';

const { Pool } = pg;

// Amazon RDS requires SSL by default (a self-managed Postgres, like Part 2's,
// doesn't) — node-postgres does NOT turn this on just because DATABASE_URL
// points at RDS, so it's a separate flag. `rejectUnauthorized: false` skips
// validating RDS's certificate chain, which is fine for a class lab; real
// production would verify against RDS's CA bundle instead.
export const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  max: Number(process.env.DB_POOL_SIZE || 10),
  ssl: process.env.PGSSL === 'true' ? { rejectUnauthorized: false } : false,
});

pool.on('error', (err) => {
  // A background/idle client died. Log it — don't crash the process over it;
  // the next query just gets a fresh connection from the pool.
  logger.error({ err }, 'unexpected Postgres pool error');
});
