const functions = require('@google-cloud/functions-framework');
const { VertexAI } = require('@google-cloud/vertexai');
const admin = require('firebase-admin');

// ─── Firebase Admin: mismo proyecto GCP → sin service account manual ─────────
// Al correr en Cloud Functions dentro de wati-497921, las credenciales
// por defecto (ADC) ya tienen acceso a Firestore y FCM del mismo proyecto.
if (admin.apps.length === 0) {
  admin.initializeApp(); // Application Default Credentials — sin JSON extra
}

const db = admin.firestore();

const PROJECT_ID     = process.env.GCP_PROJECT_ID  || 'wati-497921';
const VERTEX_LOCATION = process.env.VERTEX_LOCATION || 'us-central1';
const GEMINI_MODEL   = process.env.GEMINI_MODEL     || 'gemini-2.0-flash-lite';

// ─── Helpers ─────────────────────────────────────────────────────────────────

/**
 * Busca el FCM token del usuario en Firestore.
 * Primero en `users/{userId}` → campo fcmToken (casing Flutter).
 * Fallback en `devices/{deviceId}` → campo fcmToken.
 */
async function getFcmToken(userId, deviceId) {
  if (userId) {
    const userDoc = await db.collection('users').doc(userId).get();
    if (userDoc.exists) {
      const token = userDoc.data().fcmToken || userDoc.data().fcm_token;
      if (token) return token;
    }
  }
  if (deviceId) {
    const deviceDoc = await db.collection('devices').doc(deviceId).get();
    if (deviceDoc.exists) {
      const token = deviceDoc.data().fcmToken || deviceDoc.data().fcm_token;
      if (token) return token;
    }
  }
  return null;
}

/**
 * Llama a Gemini (Vertex AI) para generar el texto de notificación en español.
 * Si falla, retorna un texto de fallback.
 */
async function generateNotificationText(predictedTemp, feelsLike, forecastFor, deviceId) {
  const forecastDate = new Date(forecastFor);
  const timeStr = forecastDate.toLocaleTimeString('es-BO', {
    hour: '2-digit',
    minute: '2-digit',
    timeZone: 'America/La_Paz',
  });

  const advice =
    predictedTemp >= 32 ? 'La temperatura es MUY ALTA. Recomienda ventilación urgente o aire acondicionado.' :
    predictedTemp >= 28 ? 'La temperatura es alta. Sugiere cerrar persianas o encender un ventilador.' :
                          'Temperatura agradable. Recomienda aprovechar la ventilación natural.';

  const prompt =
`Eres un asistente del hogar inteligente. Genera una notificación push breve y amigable en español.

Datos:
- Sensor: ${deviceId}
- En 6 horas (~${timeStr}) la temperatura interior llegará a ${predictedTemp}°C
- Sensación térmica estimada: ${feelsLike}°C
- Contexto: ${advice}

Reglas:
- Máximo 2 frases (máx 30 palabras en total).
- Al menos una acción concreta.
- Tono amable y cotidiano.
- SIN emojis especiales, SIN comillas, SIN explicaciones extra.

Responde SOLO con el texto de la notificación.`;

  const vertex = new VertexAI({ project: PROJECT_ID, location: VERTEX_LOCATION });
  const model  = vertex.getGenerativeModel({ model: GEMINI_MODEL });
  const result = await model.generateContent(prompt);
  return (result.response.candidates?.[0]?.content?.parts?.[0]?.text || '').trim();
}

/**
 * Envía la push notification via Firebase Cloud Messaging.
 */
async function sendFcmNotification(fcmToken, title, body, extraData) {
  const message = {
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
    apns: {
      payload: { aps: { sound: 'default', badge: 1 } },
    },
  };

  return admin.messaging().send(message); // retorna message ID string
}

// ─── Cloud Function handler (trigger: Pub/Sub topic `notifications`) ─────────

functions.cloudEvent('notificationAgent', async (cloudEvent) => {
  try {
    const base64Data = cloudEvent.data?.message?.data;
    if (!base64Data) {
      console.error('[notification-agent] Pub/Sub message sin data — ignorando');
      return;
    }

    const payload = JSON.parse(Buffer.from(base64Data, 'base64').toString('utf8'));
    console.log('[notification-agent] Payload recibido:', JSON.stringify(payload));

    const { device_id, predicted_temp, feels_like, forecast_for, user_id } = payload;

    if (!device_id || predicted_temp === undefined) {
      console.error('[notification-agent] Campos requeridos faltantes en payload');
      return;
    }

    // 1. FCM token
    const fcmToken = await getFcmToken(user_id, device_id);
    if (!fcmToken) {
      console.warn(`[notification-agent] Sin FCM token para user=${user_id} device=${device_id} — skip`);
      return;
    }

    // 2. Texto generado por Gemini (con fallback)
    let notificationBody;
    try {
      notificationBody = await generateNotificationText(
        predicted_temp,
        feels_like ?? predicted_temp,
        forecast_for,
        device_id
      );
      console.log(`[notification-agent] Gemini: "${notificationBody}"`);
    } catch (geminiErr) {
      console.warn('[notification-agent] Gemini falló, usando fallback:', geminiErr.message);
      notificationBody = `En 6 horas la temperatura llegará a ${predicted_temp}°C. Considera ventilar el espacio.`;
    }

    // 3. Título según severidad
    const title =
      predicted_temp >= 32 ? 'Alerta de calor' :
      predicted_temp >= 28 ? 'Temperatura alta proxima' :
                             'Pronostico de temperatura';

    // 4. Enviar FCM
    const msgId = await sendFcmNotification(fcmToken, title, notificationBody, {
      predicted_temp,
      feels_like: feels_like ?? predicted_temp,
      forecast_for,
      device_id,
    });
    console.log(`[notification-agent] FCM enviado id=${msgId} user=${user_id} device=${device_id}`);

    // 5. Auditoría en Firestore
    await db.collection('notification_log').add({
      device_id,
      user_id:            user_id || null,
      predicted_temp,
      feels_like:         feels_like ?? predicted_temp,
      forecast_for,
      notification_title: title,
      notification_body:  notificationBody,
      fcm_message_id:     msgId,
      sent_at:            admin.firestore.FieldValue.serverTimestamp(),
    });

  } catch (err) {
    // No rethrow → Pub/Sub ack; evita bucle infinito en errores permanentes
    console.error('[notification-agent] Error fatal:', err);
  }
});
