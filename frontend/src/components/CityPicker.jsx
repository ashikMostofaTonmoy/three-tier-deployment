// A short list of cities. Each one is just a name plus its latitude/longitude,
// which is what the weather API needs. Add your own here if you like.
export const CITIES = [
  { name: 'Dhaka',     latitude: 23.8103, longitude: 90.4125 },
  { name: 'Singapore', latitude: 1.3521,  longitude: 103.8198 },
  { name: 'London',    latitude: 51.5072, longitude: -0.1276 },
  { name: 'New York',  latitude: 40.7128, longitude: -74.0060 },
  { name: 'Tokyo',     latitude: 35.6762, longitude: 139.6503 },
];

export default function CityPicker({ value, onChange }) {
  return (
    <div className="city-picker">
      {CITIES.map((city) => (
        <button
          key={city.name}
          type="button"
          className={city.name === value ? 'chip chip-active' : 'chip'}
          onClick={() => onChange(city.name)}
        >
          {city.name}
        </button>
      ))}
    </div>
  );
}
