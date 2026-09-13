// PM2 process definition for the backend. The two settings that make
// deploys zero-downtime:
//   - exec_mode: "cluster"   multiple Node processes share port 3000
//   - instances: 2           so "pm2 reload" can restart them ONE AT A TIME —
//                            at least one is always up and accepting requests
// Deploy with "pm2 reload backend", never "pm2 restart backend" (restart
// stops everything first, which is the whole outage this avoids).
module.exports = {
  apps: [
    {
      name: 'backend',
      script: 'src/server.js',
      cwd: __dirname,
      exec_mode: 'cluster',
      instances: Number(process.env.PM2_INSTANCES || 2),
      kill_timeout: 5000, // give an in-flight request up to 5s to finish before force-kill
      env: {
        NODE_ENV: 'production',
      },
    },
  ],
};
