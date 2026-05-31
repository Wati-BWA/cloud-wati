const { Firestore } = require('@google-cloud/firestore');
const db = new Firestore({ projectId: 'demo-local' });
(async () => {
  const ref = db.collection('devices').doc('device-sim-01');
  await ref.set({ temperature_celsius: 23.5, event_timestamp: new Date().toISOString() });
  const snap = await ref.get();
  console.log(JSON.stringify(snap.data()));
})().catch(err => { console.error(err); process.exit(1); });
