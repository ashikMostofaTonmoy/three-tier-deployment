import { useEffect, useState } from 'react';
import CityPicker, { CITIES } from './components/CityPicker.jsx';
import WeatherCard from './components/WeatherCard.jsx';
import BuildInfo from './components/BuildInfo.jsx';
import { getForecast } from './api.js';

export default function App() {
  const [cityName, setCityName] = useState(CITIES[0].name);
  const [data, setData] = useState(null);
  const [error, setError] = useState(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const city = CITIES.find((c) => c.name === cityName);
    let cancelled = false;

    setLoading(true);
    setError(null);

    getForecast(city)
      .then((json) => {
        if (!cancelled) setData(json);
      })
      .catch((err) => {
        if (!cancelled) setError(err.message);
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });

    return () => {
      cancelled = true;
    };
  }, [cityName]);

  return (
    <div className="page">
      <header className="header">
        <h1>Weather Board</h1>
        <p className="subtitle">A tiny frontend, deployed the DevOps way.</p>
      </header>

      <CityPicker value={cityName} onChange={setCityName} />

      <main className="panel">
        {loading && <p className="state">Loading {cityName}…</p>}
        {error && (
          <p className="state state-error">
            Could not load weather: {error}
          </p>
        )}
        {!loading && !error && data && <WeatherCard city={cityName} data={data} />}
      </main>

      <BuildInfo />
    </div>
  );
}
