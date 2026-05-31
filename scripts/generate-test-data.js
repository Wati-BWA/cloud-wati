#!/usr/bin/env node
/**
 * scripts/generate-test-data.js
 * Genera archivos NDJSON de prueba para testear process-gcs-batch
 *
 * Uso:
 *   node scripts/generate-test-data.js [--count 50] [--device TBOT-SCZ-00142]
 *   node scripts/generate-test-data.js | gsutil cp - gs://cloud-wati-iot-raw/uploads/uid_test/2026-05-30/device_test.ndjson
 */

const args     = process.argv.slice(2);
const count    = parseInt(args[args.indexOf('--count')  + 1] || '10');
const deviceId = args[args.indexOf('--device') + 1] || 'TBOT-SCZ-00142';
const userId   = args[args.indexOf('--user')   + 1] || 'uid_test';

for (let i = 0; i < count; i++) {
  const record = {
    hardware: {
      device_id:        deviceId,
      firmware_version: '1.0.7',
    },
    tenant: {
      user_id: userId,
    },
    telemetry: {
      temp_interior_c:  +(20 + Math.random() * 10).toFixed(2),
      temp_exterior_c:  +(25 + Math.random() * 10).toFixed(2),
      samples_averaged: Math.floor(1 + Math.random() * 5),
    },
    diagnostics: {
      uptime_s:      Math.floor(i * 30 + Math.random() * 5),
      wifi_rssi_dbm: -Math.floor(50 + Math.random() * 30),
    },
  };
  process.stdout.write(JSON.stringify(record) + '\n');
}
