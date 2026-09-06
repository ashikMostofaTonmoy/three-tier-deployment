// __BUILD_ID__ is replaced with a real string when the app is built
// (see frontend/vite.config.js). Showing it on screen means you can look at
// the running site and know exactly which build is live right now.
const BUILD_ID = __BUILD_ID__;

export default function BuildInfo() {
  return (
    <footer className="build-info">
      build <code>{BUILD_ID}</code>
    </footer>
  );
}
