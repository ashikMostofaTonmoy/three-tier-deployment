// The ONE place the backend talks to Postgres (Tier 3).
//
// A Pool, not a single Client: each incoming request borrows a connection,
// uses it, and gives it back — so many requests can be handled concurrently
// without each one paying the cost of a fresh TCP+auth handshake to Postgres.
import pg from 'pg';

const { Pool } = pg;

export const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  max: Number(process.env.DB_POOL_SIZE || 10),
});

pool.on('error', (err) => {
  // A background/idle client died. Log it — don't crash the process over it;
  // the next query just gets a fresh connection from the pool.
  console.error('unexpected Postgres pool error:', err.message);
});
