/**
 * LSEG Data Operations Hub — Password-Protected Server
 * 
 * Usage:
 *   1. Install dependencies:  npm install
 *   2. Set environment variables (optional):
 *        APP_USER=admin  APP_PASS=yourpassword  PORT=3000
 *   3. Start:  node server.js
 *   4. Open:   http://localhost:3000
 * 
 * Default credentials: admin / lseg2024
 * 
 * To share: run this on a cloud VM, or use ngrok/Cloudflare Tunnel for instant sharing.
 */

const express = require('express');
const basicAuth = require('express-basic-auth');
const path = require('path');
const compression = require('compression');

const app = express();
const PORT = process.env.PORT || 3000;

// ── Password Protection ──────────────────────────────────────────
const APP_USER = process.env.APP_USER || 'admin';
const APP_PASS = process.env.APP_PASS || 'lseg2024';

app.use(basicAuth({
  users: { [APP_USER]: APP_PASS },
  challenge: true,
  realm: 'LSEG Data Operations Hub',
  unauthorizedResponse: function (req) {
    return 'Access denied. Please provide valid credentials.';
  }
}));

// ── Compression & Static Files ───────────────────────────────────
app.use(compression());

// Serve static files from this directory
app.use(express.static(path.join(__dirname), {
  extensions: ['html'],
  index: 'lseg-poc-integrated.html'
}));

// Fallback: serve the main page for any unmatched route
app.get('*', function (req, res) {
  res.sendFile(path.join(__dirname, 'lseg-poc-integrated.html'));
});

// ── Start Server ─────────────────────────────────────────────────
app.listen(PORT, '0.0.0.0', function () {
  console.log('');
  console.log('  ╔══════════════════════════════════════════════╗');
  console.log('  ║   LSEG Data Operations Hub                  ║');
  console.log('  ║   Running at: http://localhost:' + PORT + '          ║');
  console.log('  ║   User: ' + APP_USER + '  Pass: ' + APP_PASS + '             ║');
  console.log('  ╚══════════════════════════════════════════════╝');
  console.log('');
  console.log('  To share externally:');
  console.log('    • ngrok:   npx ngrok http ' + PORT);
  console.log('    • Cloudflare Tunnel: cloudflared tunnel --url http://localhost:' + PORT);
  console.log('    • Deploy to cloud VM and open port ' + PORT);
  console.log('');
});
