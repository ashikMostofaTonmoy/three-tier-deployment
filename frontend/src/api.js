// The ONE place the app talks to the outside world.
//
// Every call goes to a path that starts with "/api". We never write
// "https://api.open-meteo.com" anywhere in the app. Why:
//   - in local dev, Vite forwards /api -> Open-Meteo (see vite.config.js)
//   - in production, Nginx forwards /api -> Open-Meteo (see nginx/three-tier.conf)
// The browser only ever talks to its own origin, so there are no CORS problems
// and no environment-specific URLs baked into the build.

const BASE = '/api';

export async function getForecast({ latitude, longitude, name }) {
  const params = new URLSearchParams({
    latitude,
    longitude,
    current: 'temperature_2m,relative_humidity_2m,wind_speed_10m,weather_code',
    daily: 'temperature_2m_max,temperature_2m_min,weather_code',
    timezone: 'auto',
    forecast_days: '3',
  });
  // "city" is only used server-side (Tier 2 logs it to Postgres, Part 2 only).
  // Against Part 1's setup (Nginx -> Open-Meteo directly) it's just an extra
  // query param Open-Meteo ignores — harmless either way.
  if (name) params.set('city', name);

  const res = await fetch(`${BASE}/v1/forecast?${params}`);
  if (!res.ok) {
    throw new Error(`Weather service returned ${res.status}`);
  }
  return res.json();
}

// Recent search history. Only exists when the app is deployed against the
// full three-tier stack (Part 2) — its own backend + Postgres. Against
// Part 1's setup this 404s (Open-Meteo has no such path); callers should
// treat any failure here as "feature not available", not an error to show.
export async function getHistory() {
  const res = await fetch(`${BASE}/v1/history`);
  if (!res.ok) {
    throw new Error(`history service returned ${res.status}`);
  }
  return res.json();
}
