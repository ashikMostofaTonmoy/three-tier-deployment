// Structured logging. Every log line is one JSON object on stdout instead of
// a free-text string — a machine (Promtail/Loki, or `jq` on the command line)
// can parse "level", "msg", "err", etc. reliably; console.log can't guarantee
// any of that. PM2 already captures this process's stdout into
// ~/.pm2/logs/backend-out-*.log with zero extra config — Promtail just tails
// that file (see monitoring/promtail-config.yml).
import pino from 'pino';

export const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  timestamp: pino.stdTimeFunctions.isoTime,
});
