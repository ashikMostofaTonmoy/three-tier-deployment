// The ONE place the app talks to the outside world.
//
// Every call goes to a path that starts with "/api". We never write
// "https://api.open-meteo.com" anywhere in the app. Why:
//   - in local dev, Vite forwards /api -> Open-Meteo (see vite.config.js)
//   - in production, Nginx forwards /api -> Open-Meteo (see nginx/three-tier.conf)
// The browser only ever talks to its own origin, so there are no CORS problems
// and no environment-specific URLs baked into the build.

const BASE = '/api';

export async function getForecast({ latitude, longitude }) {
  const params = new URLSearchParams({
    latitude,
    longitude,
    current: 'temperature_2m,relative_humidity_2m,wind_speed_10m,weather_code',
    daily: 'temperature_2m_max,temperature_2m_min,weather_code',
    timezone: 'auto',
    forecast_days: '3',
  });

  const res = await fetch(`${BASE}/v1/forecast?${params}`);
  if (!res.ok) {
    throw new Error(`Weather service returned ${res.status}`);
  }
  return res.json();
}
