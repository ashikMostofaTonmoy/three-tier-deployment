// Tier 2 — the app/API tier.
//
// This is the ONLY thing in the whole stack that talks to Open-Meteo AND the
// ONLY thing that talks to Postgres. The frontend never does either directly —
// it only ever calls this service (through Nginx's /api/ proxy).
import 'dotenv/config'; // loads .env into process.env — PM2 does not do this itself
import express from 'express';
import { pool } from './db.js';
import { logger } from './logger.js';
import {
  metricsMiddleware,
  weatherSearchesTotal,
  weatherCurrentTemperature,
  startMetricsServer,
} from './metrics.js';

const app = express();
const PORT = process.env.PORT || 3000;

app.use(metricsMiddleware);

app.get('/health', (req, res) => {
  res.json({ status: 'ok' });
});

// --- /metrics lives on its OWN port, not this one — see the comment in
// metrics.js's cluster-mode section for why. It is NOT behind Nginx's /api/
// proxy either way, so it is unreachable from the internet regardless.

// GET /api/v1/forecast?latitude=..&longitude=..&city=Dhaka
//
// Fetches the weather from Open-Meteo (server-side — the browser never talks
// to Open-Meteo directly) and, best-effort, logs the query to Postgres so the
// /api/v1/history endpoint has something to show. A failed history write is
// logged and ignored: the primary feature (showing the weather) must never
// break because of a secondary one (remembering that you asked).
app.get('/api/v1/forecast', async (req, res) => {
  const { latitude, longitude, city } = req.query;
  if (!latitude || !longitude) {
    return res.status(400).json({ error: true, reason: 'latitude and longitude are required' });
  }

  try {
    const params = new URLSearchParams({
      latitude,
      longitude,
      current: 'temperature_2m,relative_humidity_2m,wind_speed_10m,weather_code',
      daily: 'temperature_2m_max,temperature_2m_min,weather_code',
      timezone: 'auto',
      forecast_days: '3',
    });

    const upstream = await fetch(`https://api.open-meteo.com/v1/forecast?${params}`);
    const data = await upstream.json();

    if (upstream.ok) {
      const temperature = data.current?.temperature_2m ?? null;
      const cityLabel = city || 'unknown';

      // business metrics — see backend/src/metrics.js for why these are
      // kept conceptually separate from the generic HTTP metrics above
      weatherSearchesTotal.inc({ city: cityLabel });
      if (typeof temperature === 'number') {
        weatherCurrentTemperature.set({ city: cityLabel }, temperature);
      }

      pool
        .query(
          `INSERT INTO search_history (city, latitude, longitude, temperature)
           VALUES ($1, $2, $3, $4)`,
          [city || null, latitude, longitude, temperature],
        )
        .catch((err) => logger.error({ err }, 'history insert failed (non-fatal)'));
    }

    logger.info({ city, latitude, longitude, status: upstream.status }, 'forecast lookup');
    res.status(upstream.status).json(data);
  } catch (err) {
    logger.error({ err, city, latitude, longitude }, 'forecast lookup failed');
    res.status(502).json({ error: true, reason: err.message });
  }
});

// GET /api/v1/history — what has been searched recently. Powers the
// frontend's "Recent searches" panel.
app.get('/api/v1/history', async (req, res) => {
  try {
    const { rows } = await pool.query(
      `SELECT city, latitude, longitude, temperature, queried_at
       FROM search_history
       ORDER BY queried_at DESC
       LIMIT 10`,
    );
    res.json({ rows });
  } catch (err) {
    logger.error({ err }, 'history query failed');
    res.status(500).json({ error: true, reason: err.message });
  }
});

app.listen(PORT, () => {
  logger.info({ pid: process.pid, port: PORT }, 'backend listening');
});

startMetricsServer();
