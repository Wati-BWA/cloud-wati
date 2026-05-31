'use strict';

/**
 * Cloud Function 2gen: refresh-latest
 * Trigger: Cloud Scheduler HTTP cada 5 minutos
 * Runtime: Node.js 20 | Memory: 256 MB | Timeout: 120s
 *
 * Actualiza la tabla `latest_per_device` con MERGE desde `raw_telemetry`.
 * Usa partición de 1 día para no exceder el free tier de 1 TB/mes.
 */

const { BigQuery } = require('@google-cloud/bigquery');
const bigquery = new BigQuery();

const PROJECT   = process.env.GCP_PROJECT_ID;
const DATASET   = process.env.BQ_DATASET   || 'iot_telemetry';
const RAW       = process.env.BQ_RAW_TABLE || 'raw_telemetry';
const LATEST    = process.env.BQ_LATEST_TABLE || 'latest_per_device';

exports.refreshLatest = async (req, res) => {
  if (!PROJECT) {
    return res.status(500).json({ error: 'GCP_PROJECT_ID not set' });
  }

  // Query acotado a 1 día para evitar scan completo (free tier protección)
  const query = `
    MERGE \`${PROJECT}.${DATASET}.${LATEST}\` T
    USING (
      SELECT *
      FROM (
        SELECT
          device_id,
          user_id,
          timestamp,
          temp_interior_c,
          temp_exterior_c,
          samples_averaged,
          uptime_s,
          wifi_rssi_dbm,
          firmware_version,
          ingest_source,
          ROW_NUMBER() OVER (PARTITION BY device_id ORDER BY timestamp DESC) AS rn
        FROM \`${PROJECT}.${DATASET}.${RAW}\`
        WHERE DATE(timestamp) >= DATE_SUB(CURRENT_DATE(), INTERVAL 1 DAY)
      )
      WHERE rn = 1
    ) S
    ON T.device_id = S.device_id
    WHEN MATCHED THEN
      UPDATE SET
        user_id          = S.user_id,
        timestamp        = S.timestamp,
        temp_interior_c  = S.temp_interior_c,
        temp_exterior_c  = S.temp_exterior_c,
        samples_averaged = S.samples_averaged,
        uptime_s         = S.uptime_s,
        wifi_rssi_dbm    = S.wifi_rssi_dbm,
        firmware_version = S.firmware_version,
        updated_at       = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN
      INSERT (device_id, user_id, timestamp, temp_interior_c, temp_exterior_c,
              samples_averaged, uptime_s, wifi_rssi_dbm, firmware_version, updated_at)
      VALUES (S.device_id, S.user_id, S.timestamp, S.temp_interior_c, S.temp_exterior_c,
              S.samples_averaged, S.uptime_s, S.wifi_rssi_dbm, S.firmware_version, CURRENT_TIMESTAMP())
  `;

  try {
    const [job] = await bigquery.createQueryJob({ query, location: 'US' });
    await job.getQueryResults();

    const stats = job.metadata?.statistics;
    console.log(`refresh-latest: MERGE OK. Bytes processed: ${stats?.query?.totalBytesProcessed ?? 'N/A'}`);

    return res.status(200).json({
      status: 'refreshed',
      bytes_processed: stats?.query?.totalBytesProcessed ?? null,
    });
  } catch (err) {
    console.error('refresh-latest error:', err);
    return res.status(500).json({ error: err.message });
  }
};
