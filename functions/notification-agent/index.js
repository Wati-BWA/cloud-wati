const functions = require('@google-cloud/functions-framework');
const { Firestore } = require('@google-cloud/firestore');
const { VertexAI } = require('@google-cloud/vertexai');

// Firebase Admin initialized lazily with injected service account from Secret Manager
let adminApp = null;

const firestore = new Firestore();

const PROJECT_ID = process.env.GCP_PROJECT_ID || 'wati-497921';
const VERTEX_LOCATION = process.env.VERTEX_LOCATION || 'us-central1';
const GEMINI_MODEL = process.env.GEMINI_MODEL || 'gemini-2.0-flash-lite';

/**
 * Initializes Firebase Admin SDK using the service account JSON from env var
 * (injected by Secret Manager via --set-secrets).
 */
function getFirebaseAdmin() {
  if (adminApp) return adminApp;

  const admin = require('firebase-admin');
  const serviceAccountJson = process.env.FIREBASE_SERVICE_ACCOUNT;

  if (!serviceAccountJson) {
    throw new Error('FIREBASE_SERVICE_ACCOUNT env var is not set');
  }

  const serviceAccount = JSON.parse(serviceAccountJson);

  if (admin.apps.length === 0) {
    adminApp = admin.initializeApp({
      credential: admin.credential.cert(serviceAccount),
    });
  } else {
    adminApp = admin.app();
  }

  return adminApp;
}

/**
 * Fetches FCM token for a user from Firestore.
 * Looks in `users/{userId}` → fcm_token field.
 * Falls back to `devices/{deviceId}` → fcm_token.
 */
async function getFcmToken(userId, deviceId) {
  // Primary: users collection
  if (userId) {
    const userDoc = await firestore.collection('users').doc(userId).get();
    if (userDoc.exists && userDoc.data().fcm_token) {
      return userDoc.data().fcm_token;
    }
  }
  // Fallback: devices collection
  if (deviceId) {
    const deviceDoc = await firestore.collection('devices').doc(deviceId).get();
    if (deviceDoc.exists && deviceDoc.data().fcm_token) {
      return deviceDoc.data().fcm_token;
    }
  }
  return null;
}

/**
 * Calls Gemini via Vertex AI to generate a friendly notification message.
 */
async function generateNotificationText(predictedTemp, feelsLike, forecastFor, deviceId) {
  const vertex = new VertexAI({ project: PROJECT_ID, location: VERTEX_LOCATION });
  const model = vertex.getGenerativeModel({ model: GEMINI_MODEL });

  // Format the forecast time for readability
  const forecastDate = new Date(forecastFor);
  const timeStr = forecastDate.toLocaleTimeString('es-BO', {
    hour: '2-digit',
    minute: '2-digit',
    timeZone: 'America/La_Paz',
  });

  const prompt = `Eres un asistente del hogar inteligente. Genera una notificación push breve y amigable en español para el usuario.
  
Datos del pronóstico:
- Sensor/ubicación: ${deviceId}
- En 6 horas (aproximadamente a las ${timeStr}), la temperatura interior alcanzará ${predictedTemp}°C
- Sensación térmica estimada: ${feelsLike}°C
${predictedTemp >= 32 ? '- La temperatura es MUY ALTA, recomienda ventilación urgente.' : predictedTemp >= 28 ? '- La temperatura es alta, sugiere cerrar persianas o encender ventilador.' : '- Temperatura moderada, recomienda mantener ventilación natural.'}

Reglas:
- Máximo 2 frases cortas (máx 25 palabras en total).
- Incluye al menos una acción concreta y amigable.
- No menciones números técnicos como intervalos de confianza.
- Usa tono amable y cotidiano.
- No uses emojis especiales que puedan romperse.

Responde SOLO con el texto de la notificación, sin comillas ni explicaciones.`;

  const result = await model.generateContent(prompt);
  const response = result.response;
  const text = response.candidates?.[0]?.content?.parts?.[0]?.text || '';
  return text.trim();
}

/**
 * Sends a push notification via Firebase Cloud Messaging.
 */
async function sendFcmNotification(fcmToken, title, body, data) {
  const admin = require('firebase-admin');
  getFirebaseAdmin(); // ensure initialized

  const message = {
    token: fcmToken,
    notification: {
      title,
      body,
    },
    data: {
      predicted_temp: String(data.predicted_temp),
      feels_like: String(data.feels_like),
      forecast_for: data.forecast_for,
      device_id: data.device_id,
    },
    android: {
      priority: 'high',
      notification: {
        sound: 'default',
        channelId: 'temperature_alerts',
      },
    },
    apns: {
      payload: {
        aps: {
          sound: 'default',
          badge: 1,
        },
      },
    },
  };

  const response = await admin.messaging().send(message);
  return response;
}

/**
 * Cloud Function triggered by Pub/Sub topic `notifications`.
 * Receives base64-encoded JSON message with prediction data.
 */
functions.cloudEvent('notificationAgent', async (cloudEvent) => {
  try {
    // Decode Pub/Sub message
    const base64Data = cloudEvent.data?.message?.data;
    if (!base64Data) {
      console.error('[notification-agent] No data in Pub/Sub message');
      return;
    }

    const messageStr = Buffer.from(base64Data, 'base64').toString('utf8');
    const payload = JSON.parse(messageStr);
    console.log('[notification-agent] Received payload:', JSON.stringify(payload));

    const { device_id, predicted_temp, feels_like, forecast_for, user_id } = payload;

    if (!device_id || predicted_temp === undefined) {
      console.error('[notification-agent] Missing required fields in payload');
      return;
    }

    // 1. Get FCM token
    const fcmToken = await getFcmToken(user_id, device_id);
    if (!fcmToken) {
      console.log(`[notification-agent] No FCM token found for user=${user_id}, device=${device_id} — skip`);
      return;
    }

    // 2. Generate notification text with Gemini
    let notificationBody;
    try {
      notificationBody = await generateNotificationText(
        predicted_temp,
        feels_like || predicted_temp,
        forecast_for,
        device_id
      );
      console.log(`[notification-agent] Gemini generated: "${notificationBody}"`);
    } catch (geminiErr) {
      console.warn('[notification-agent] Gemini error, using fallback text:', geminiErr.message);
      // Fallback message if Gemini fails
      notificationBody = `En 6 horas la temperatura llegará a ${predicted_temp}°C. Considera ventilar tu espacio.`;
    }

    // 3. Send FCM notification
    const title = predicted_temp >= 32
      ? '🌡️ Alerta de calor'
      : predicted_temp >= 28
        ? '☀️ Temperatura alta próxima'
        : '🌤️ Pronóstico de temperatura';

    const msgId = await sendFcmNotification(fcmToken, title, notificationBody, {
      predicted_temp,
      feels_like: feels_like || predicted_temp,
      forecast_for,
      device_id,
    });

    console.log(`[notification-agent] FCM message sent: ${msgId} to user=${user_id}, device=${device_id}`);

    // 4. Log to Firestore for audit trail
    await firestore.collection('notification_log').add({
      device_id,
      user_id: user_id || null,
      predicted_temp,
      feels_like: feels_like || predicted_temp,
      forecast_for,
      notification_title: title,
      notification_body: notificationBody,
      fcm_message_id: msgId,
      sent_at: new Date().toISOString(),
    });

  } catch (err) {
    console.error('[notification-agent] Fatal error:', err);
    // Do not rethrow — let Pub/Sub ack the message to avoid infinite retries on permanent errors
    // For retryable errors (e.g., network), throwing would cause redelivery
  }
});
