module.exports = {
  apps: [{
    name:               'bridge',
    script:             './server.js',
    cwd:                __dirname,
    node_args:          '--max-old-space-size=512',
    max_memory_restart: '600M',   // reinicia se heap ultrapassar 600 MB
    autorestart:        true,
    watch:              false,
    max_restarts:       20,
    min_uptime:         '10s',
    restart_delay:      3000,     // espera 3s entre restarts
    kill_timeout:       8000,
    error_file:         './pm2-logs/err.log',
    out_file:           './pm2-logs/out.log',
    log_date_format:    'YYYY-MM-DD HH:mm:ss Z',
    merge_logs:         true,
  }],
};
