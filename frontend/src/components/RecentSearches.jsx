import { useEffect, useState } from 'react';
import { getHistory } from '../api.js';

// Shows Tier 3 (Postgres) data, fetched through Tier 2 (the backend). Only
// meaningful when this app is deployed against the full three-tier stack —
// against Part 1's Open-Meteo-direct setup, getHistory() fails and this
// component just renders nothing. It never shows an error to the user; a
// missing "nice to have" panel is not worth alarming anyone over.
export default function RecentSearches({ refreshKey }) {
  const [rows, setRows] = useState(null);
  const [available, setAvailable] = useState(true);

  useEffect(() => {
    if (!available) return;
    getHistory()
      .then((json) => setRows(json.rows || []))
      .catch(() => setAvailable(false));
  }, [refreshKey, available]);

  if (!available || !rows || rows.length === 0) return null;

  return (
    <div className="card">
      <h2>Recent searches</h2>
      <ul className="history-list">
        {rows.map((r, i) => (
          <li key={i}>
            <span className="history-city">{r.city || 'Unknown'}</span>
            <span className="history-temp">{r.temperature != null ? `${Math.round(r.temperature)}°C` : '—'}</span>
            <span className="history-time">
              {new Date(r.queried_at).toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' })}
            </span>
          </li>
        ))}
      </ul>
    </div>
  );
}
