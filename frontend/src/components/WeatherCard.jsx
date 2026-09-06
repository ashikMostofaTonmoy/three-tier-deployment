// Turns Open-Meteo's numeric "weather_code" into a word + an emoji.
// Full table: https://open-meteo.com/en/docs
function describe(code) {
  if (code === 0) return { icon: '☀️', text: 'Clear sky' };
  if (code <= 2) return { icon: '🌤️', text: 'Mostly clear' };
  if (code === 3) return { icon: '☁️', text: 'Overcast' };
  if (code <= 48) return { icon: '🌫️', text: 'Fog' };
  if (code <= 57) return { icon: '🌦️', text: 'Drizzle' };
  if (code <= 67) return { icon: '🌧️', text: 'Rain' };
  if (code <= 77) return { icon: '❄️', text: 'Snow' };
  if (code <= 82) return { icon: '🌧️', text: 'Rain showers' };
  if (code <= 86) return { icon: '🌨️', text: 'Snow showers' };
  return { icon: '⛈️', text: 'Thunderstorm' };
}

export default function WeatherCard({ city, data }) {
  const now = data.current;
  const units = data.current_units;
  const today = describe(now.weather_code);

  return (
    <div className="weather">
      <div className="weather-now">
        <div className="weather-icon">{today.icon}</div>
        <div>
          <div className="weather-temp">
            {Math.round(now.temperature_2m)}{units.temperature_2m}
          </div>
          <div className="weather-desc">{today.text} · {city}</div>
          <div className="weather-meta">
            Humidity {now.relative_humidity_2m}{units.relative_humidity_2m}
            {'  ·  '}
            Wind {Math.round(now.wind_speed_10m)} {units.wind_speed_10m}
          </div>
        </div>
      </div>

      <div className="forecast">
        {data.daily.time.map((day, i) => {
          const d = describe(data.daily.weather_code[i]);
          const label = new Date(day).toLocaleDateString(undefined, { weekday: 'short' });
          return (
            <div className="forecast-day" key={day}>
              <div className="forecast-dow">{i === 0 ? 'Today' : label}</div>
              <div className="forecast-icon">{d.icon}</div>
              <div className="forecast-range">
                {Math.round(data.daily.temperature_2m_max[i])}° / {Math.round(data.daily.temperature_2m_min[i])}°
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}
