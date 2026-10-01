// Renders the n8n credentials LeadOps needs from environment variables.
// Runs inside the n8n container:  node /import/render-credentials.js > /tmp/leadops-credentials.json
// n8n encrypts them on import (n8n import:credentials).
const e = process.env;
const creds = [
  { id: 'loCredPostgres01', name: 'LeadOps DB', type: 'postgres', data: {
      host: e.LEADOPS_DB_HOST || 'postgres', port: Number(e.LEADOPS_DB_PORT || 5432),
      database: e.LEADOPS_DB_NAME || 'leadops', user: e.POSTGRES_USER || 'leadops',
      password: e.POSTGRES_PASSWORD || '', ssl: 'disable', allowUnauthorizedCerts: false } },
  { id: 'loCredSmtp000001', name: 'LeadOps SMTP', type: 'smtp', data: {
      host: e.SMTP_HOST || 'smtp.example.com', port: Number(e.SMTP_PORT || 587),
      user: e.SMTP_USER || '', password: e.SMTP_PASSWORD || '',
      secure: String(e.SMTP_SECURE || 'false') === 'true' } },
  { id: 'loCredDashAuth01', name: 'LeadOps dashboard login', type: 'httpBasicAuth', data: {
      user: e.DASHBOARD_USER || 'admissions', password: e.DASHBOARD_PASSWORD || '' } },
];
if (!creds[2].data.password) { console.error('DASHBOARD_PASSWORD is empty - set it in .env'); process.exit(1); }
process.stdout.write(JSON.stringify(creds, null, 2));
