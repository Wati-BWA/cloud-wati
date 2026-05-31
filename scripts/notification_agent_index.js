const functions = require('@google-cloud/functions-framework');
const { VertexAI } = require('@google-cloud/vertexai');
const admin = require('firebase-admin');

// ─── Firebase Admin con ADC (mismo proyecto GCP wati-497921) ────────────────
if (admin.apps.length === 0) {
  admin.initializeApp(); // Application Default Credentials — sin JSON extra
}

const db = admin.firestore();

const PROJECT_ID      = process.env.PROJECT_ID      || 'wati-497921';
const VERTEX_LOCATION = process.env.VERTEX_LOCATION || 'us-central1';
const GEMINI_MODEL    = process.env.GEMINI_MODEL    || 'gemini-2.0-flash-lite';

// ─── Helpers ─────────────────────────────────────────────────────────────────

async function getFcmToken(userId, deviceId) {
  if (userId) {
    const doc = await db.collection('users').doc(userId).get();
    if (doc.exists) {
      const token = doc.data().fcmToken || doc.data().fcm_token;
      if (token) return token;
    }
  }
  if (deviceId) {
    const doc = await db.collection('devices').doc(deviceId).get();
    if (doc.exists) {
      const token = doc.data().fcmToken || doc.data().fcm_token;
      if (token) return token;
    }
  }
  return null;
}

async function generateNotificationText(predictedTemp, feelsLike, forecastFor, deviceId) {
  const forecastDate = new Date(forecastFor);
  const timeStr = forecastDate.toLocaleTimeString('es-BO', {
    hour: '2-digit', minute: '2-digit', timeZone: 'America/La_Paz',
  });

  const advice =
    predictedTemp >= 32 ? 'La temperatura sera MUY ALTA. Recomienda ventilacion urgente.' :
    predictedTemp >= 28 ? 'La temperatura sera alta. Sugiere cerrar persianas o encender un ventilador.' :
                          'Temperatura agradable. Recomienda aprovechar ventilacion natural.';

  const prompt =
`Eres un asistente del hogar inteligente. Genera una notificacion push breve en español.

Datos:
- Sensor: ${deviceId}
- En 6 horas (~${timeStr}) la temperatura llegara a ${predictedTemp}°C (sensacion: ${feelsLike}°C)
- Consejo: ${advice}

Reglas: max 2 frases, max 30 palabras, accion concreta, tono amable, sin emojis, sin comillas.
Responde SOLO con el texto de la notificacion.`;

  const vertex = new VertexAI({ project: PROJECT_ID, location: VERTEX_LOCATION });
  const model  = vertex.getGenerativeModel({ model: GEMINI_MODEL });
  const result = await model.generateContent(prompt);
  return (result.response.candidates?.[0]?.content?.parts?.[0]?.text || '').trim();
}

async function sendFcmNotification(fcmToken, title, body, extraData) {
  return admin.messaging().send({
    token: fcmToken,
    notification: { title, body },
    data: {
      predicted_temp: String(extraData.predicted_temp),
      feels_like:     String(extraData.feels_like),
      forecast_for:   extraData.forecast_for,
      device_id:      extraData.device_id,
    },
    android: {
      priority: 'high',
      notification: { sound: 'default', channelId: 'temperature_alerts' },
    },
    apns: { payload: { aps: { sound: 'default', badge: 1 } } },
  });
}

// ─── Cloud Function (trigger: Pub/Sub topic `notifications`) ─────────────────

functions.cloudEvent('notificationAgent', async (cloudEvent) => {
  try {
    const base64Data = cloudEvent.data?.message?.data;
    if (!base64Data) {
      console.error('[notification-agent] Mensaje sin data'); return;
    }

    const payload = JSON.parse(Buffer.from(base64Data, 'base64').toString('utf8'));
    console.log('[notification-agent] Payload:', JSON.stringify(payload));

    const { device_id, predicted_temp, feels_like, forecast_for, user_id } = payload;
    if (!device_id || predicted_temp === undefined) {
      console.error('[notification-agent] Campos faltantes'); return;
    }

    // 1. Resolver user_id desde Firestore devices (si no viene en el payload)
    let resolvedUserId = user_id;
    if (!resolvedUserId) {
      const deviceDoc = await db.collection('devices').doc(device_id).get();
      if (deviceDoc.exists) resolvedUserId = deviceDoc.data().userId || deviceDoc.data().user_id;
    }

    // 2. FCM token
    const fcmToken = await getFcmToken(resolvedUserId, device_id);
    if (!fcmToken) {
      console.warn(`[notification-agent] Sin FCM token para device=${device_id}`); return;
    }

    // 3. Texto por Gemini (con fallback)
    let body;
    try {
      body = await generateNotificationText(predicted_temp, feels_like ?? predicted_temp, forecast_for, device_id);
      console.log(`[notification-agent] Gemini: "${body}"`);
    } catch (e) {
      console.warn('[notification-agent] Fallback texto:', e.message);
      body = `En 6 horas la temperatura llegara a ${predicted_temp}°C. Considera ventilar el espacio.`;
    }

    const title =
      predicted_temp >= 32 ? 'Alerta de calor' :
      predicted_temp >= 28 ? 'Temperatura alta proxima' : 'Pronostico de temperatura';

    // 4. Enviar FCM
    const msgId = await sendFcmNotification(fcmToken, title, body, {
      predicted_temp, feels_like: feels_like ?? predicted_temp, forecast_for, device_id,
    });
    console.log(`[notification-agent] FCM id=${msgId} user=${resolvedUserId}`);

    // 5. Auditoría Firestore
    await db.collection('notification_log').add({
      device_id, user_id: resolvedUserId || null,
      predicted_temp, feels_like: feels_like ?? predicted_temp,
      forecast_for, notification_title: title, notification_body: body,
      fcm_message_id: msgId,
      sent_at: admin.firestore.FieldValue.serverTimestamp(),
    });

  } catch (err) {
    console.error('[notification-agent] Error fatal:', err);
  }
});
