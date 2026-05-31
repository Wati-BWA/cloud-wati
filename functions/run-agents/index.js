'use strict';

/**
 * Cloud Function 2gen: run-agents
 * Trigger: HTTP interno (llamado por ingest-telemetry o Cloud Scheduler)
 * Runtime: Node.js 20 | Memory: 512 MB | Timeout: 120s
 * Autenticación: NO unauthenticated (solo llamadas internas)
 *
 * Orquesta el SchedulerAgent con Gemini 1.5 Flash.
 * Envía notificaciones FCM si prioridad > LOW.
 * Sin comandos a dispositivos (MVP: solo alertas informativas).
 */

const { Firestore, FieldValue } = require('@google-cloud/firestore');
const { BigQuery } = require('@google-cloud/bigquery');
const admin = require('firebase-admin');

let adminInitialized = false;
function initAdmin() {
  if (!adminInitialized) {
    admin.initializeApp();
    adminInitialized = true;
  }
}

const db = new Firestore();
const bq = new BigQuery();
const GEMINI_API_KEY = process.env.GEMINI_API_KEY;
const PROJECT_ID = process.env.GCP_PROJECT_ID || 'wati-497921';
const BQ_DATASET  = process.env.BQ_DATASET    || 'iot_telemetry';

// ──────────────────────────────────────────────
// Modo REFRESH: actualiza latest_per_device en BQ
// (consolida la función refresh-latest para ahorrar
//  un slot de Cloud Scheduler — max 3 en free tier)
// ──────────────────────────────────────────────
async function refreshLatestTable() {
  const query = `
    MERGE \`${PROJECT_ID}.${BQ_DATASET}.latest_per_device\` T
    USING (
      SELECT *
      FROM (
        SELECT *,
          ROW_NUMBER() OVER (PARTITION BY device_id ORDER BY timestamp DESC) AS rn
        FROM \`${PROJECT_ID}.${BQ_DATASET}.raw_telemetry\`
        WHERE DATE(timestamp) >= DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY)
      )
      WHERE rn = 1
    ) S
    ON T.device_id = S.device_id
    WHEN MATCHED THEN UPDATE SET
      user_id = S.user_id, timestamp = S.timestamp,
      temp_interior_c = S.temp_interior_c, temp_exterior_c = S.temp_exterior_c,
      samples_averaged = S.samples_averaged, uptime_s = S.uptime_s,
      wifi_rssi_dbm = S.wifi_rssi_dbm, firmware_version = S.firmware_version,
      updated_at = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (
      device_id, user_id, timestamp, temp_interior_c, temp_exterior_c,
      samples_averaged, uptime_s, wifi_rssi_dbm, firmware_version, updated_at
    ) VALUES (
      S.device_id, S.user_id, S.timestamp, S.temp_interior_c, S.temp_exterior_c,
      S.samples_averaged, S.uptime_s, S.wifi_rssi_dbm, S.firmware_version, CURRENT_TIMESTAMP()
    )
  `;
  const [job] = await bq.createQueryJob({ query, location: 'US' });
  await job.getQueryResults();
  console.log('latest_per_device refreshed via run-agents');
}

// ──────────────────────────────────────────────
// SchedulerAgent prompt (Gemini 1.5 Flash)
// ──────────────────────────────────────────────
function buildPrompt(deviceData, triggerReason) {
  return `
Eres un agente de monitoreo IoT para dispositivos ESP32 en Bolivia.
Analiza los siguientes datos de telemetría y genera una recomendación de notificación.

Datos del dispositivo:
- device_id: ${deviceData.device_id || 'N/A'}
- Temperatura interior: ${deviceData.temp_interior_c}°C
- Temperatura exterior: ${deviceData.temp_exterior_c}°C
- Señal WiFi: ${deviceData.wifi_rssi_dbm} dBm
- Uptime: ${deviceData.uptime_s}s
- Razón del trigger: ${triggerReason}

Responde SOLO con JSON válido con esta estructura exacta:
{
  "priority": "LOW" | "MEDIUM" | "HIGH",
  "type": "temp_alert" | "connectivity_alert" | "normal",
  "title": "Título corto (máx 50 chars)",
  "body": "Mensaje descriptivo (máx 150 chars)"
}
`.trim();
}

// ──────────────────────────────────────────────
// Llamada a Gemini 1.5 Flash via REST
// ──────────────────────────────────────────────
async function callGemini(prompt) {
  if (!GEMINI_API_KEY) {
    // Fallback heurístico si no hay API key (dev/testing)
    return buildHeuristicRecommendation(prompt);
  }

  const { default: fetch } = await import('node-fetch');
  const url = `https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=${GEMINI_API_KEY}`;

  const response = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      contents: [{ parts: [{ text: prompt }] }],
      generationConfig: { temperature: 0.1, maxOutputTokens: 256 },
    }),
  });

  if (!response.ok) {
    throw new Error(`Gemini API error: ${response.status}`);
  }

  const data = await response.json();
  const text = data.candidates?.[0]?.content?.parts?.[0]?.text || '{}';

  // Extraer JSON del texto (puede venir con markdown code fences)
  const jsonMatch = text.match(/\{[\s\S]*\}/);
  if (!jsonMatch) throw new Error('No JSON in Gemini response');

  return JSON.parse(jsonMatch[0]);
}

function buildHeuristicRecommendation(prompt) {
  // Extrae temperatura del prompt para heurística
  const tempMatch = prompt.match(/Temperatura interior: ([\d.]+)/);
  const temp = tempMatch ? parseFloat(tempMatch[1]) : 20;

  if (temp > 35) {
    return { priority: 'HIGH', type: 'temp_alert', title: 'Temperatura alta detectada', body: `Temperatura interior: ${temp}°C. Revisar ventilación.` };
  }
  if (temp < 5) {
    return { priority: 'HIGH', type: 'temp_alert', title: 'Temperatura baja detectada', body: `Temperatura interior: ${temp}°C. Riesgo de daño por frío.` };
  }
  return { priority: 'LOW', type: 'normal', title: 'Telemetría normal', body: 'Dispositivo operando dentro de parámetros.' };
}

// ──────────────────────────────────────────────
// Envío FCM
// ──────────────────────────────────────────────
async function sendFCMNotification(fcmToken, notification) {
  if (!fcmToken) return;
  try {
    await admin.messaging().send({
      token: fcmToken,
      notification: {
        title: notification.title,
        body:  notification.body,
      },
      data: { type: notification.type, priority: notification.priority },
    });
  } catch (err) {
    console.error('FCM send error:', err.message);
  }
}

// ──────────────────────────────────────────────
// Handler principal
// ──────────────────────────────────────────────
exports.runAgents = async (req, res) => {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'method_not_allowed' });
  }

  const { device_id, trigger_reason } = req.body || {};

  // ── Modo REFRESH (consolida refresh-latest para ahorrar job slot de Scheduler)
  if (trigger_reason === 'refresh' || req.body?.trigger === 'refresh') {
    try {
      await refreshLatestTable();
      return res.status(200).json({ status: 'refreshed', trigger: 'refresh' });
    } catch (err) {
      console.error('refresh error:', err);
      return res.status(500).json({ error: 'refresh_failed', message: err.message });
    }
  }

  // ── Modo AGENTS: requiere device_id
  if (!device_id) {
    return res.status(400).json({ error: 'device_id required (or pass trigger:"refresh")' });
  }

  // 1. Leer contexto desde Firestore (1 lectura)
  const deviceSnap = await db.collection('devices').doc(device_id).get();
  if (!deviceSnap.exists) {
    return res.status(404).json({ error: 'device_not_found' });
  }
  const deviceData = { device_id, ...deviceSnap.data() };

  // 2. Llamar a Gemini SchedulerAgent
  const prompt = buildPrompt(deviceData, trigger_reason || 'scheduled_check');
  let recommendation;
  try {
    recommendation = await callGemini(prompt);
  } catch (err) {
    console.error('Agent error:', err);
    recommendation = buildHeuristicRecommendation(prompt);
  }

  // 3. Consultar predicción (aumento > 2°C en próximas 6 hrs)
  try {
    const PROJECT = process.env.GCP_PROJECT_ID || 'wati-497921';
    const DATASET = process.env.BQ_DATASET || 'iot_telemetry';
    const query = `
      SELECT MAX(predicted_temp_c) AS max_predicted_temp
      FROM \`${PROJECT}.${DATASET}.temperature_predictions\`
      WHERE device_id = @device_id
        AND prediction_hour >= CURRENT_TIMESTAMP()
        AND prediction_hour <= TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 6 HOUR)
    `;
    const [rows] = await bq.query({ query, params: { device_id }, location: 'US' });
    if (rows && rows.length > 0 && rows[0].max_predicted_temp) {
      const maxPredicted = rows[0].max_predicted_temp;
      const currentTemp = deviceData.temp_interior_c || 0;
      if (maxPredicted - currentTemp > 2.0) {
        recommendation.priority = 'HIGH';
        recommendation.type = 'temp_alert';
        recommendation.title = 'Alerta de predicción de temperatura';
        recommendation.body = \`Se prevé un aumento a \${maxPredicted.toFixed(1)}°C (+\${(maxPredicted - currentTemp).toFixed(1)}°C) en las próximas 6h.\`;
      }
    }
  } catch (err) {
    console.error('Error fetching prediction in run-agents:', err);
  }

  // 4. Solo alertas informativas (sin comandos a dispositivos)
  if (recommendation.priority !== 'LOW') {
    initAdmin();

    // FCM al token del usuario (guardado en users/{uid})
    const userSnap = await db.collection('users').doc(deviceData.user_id || '').get().catch(() => null);
    const fcmToken = userSnap?.data()?.fcm_token;
    await sendFCMNotification(fcmToken, recommendation);

    // Guardar en historial de notificaciones del dispositivo
    await db.collection('devices').doc(device_id)
      .collection('notifications')
      .add({
        type:       recommendation.type,
        title:      recommendation.title,
        body:       recommendation.body,
        priority:   recommendation.priority,
        trigger:    trigger_reason,
        created_at: FieldValue.serverTimestamp(),
      });
  }

  return res.status(200).json({
    status:         'agents_executed',
    device_id,
    recommendation,
  });
};
