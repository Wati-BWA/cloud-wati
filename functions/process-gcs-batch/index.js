const { BigQuery } = require('@google-cloud/bigquery');
const bigquery = new BigQuery();

exports.processGcsBatch = async (file, context) => {
    console.log(`Processing file: ${file.name}`);
    
    const datasetId = 'iot_dataset';
    const tableId = 'telemetry_raw';
    
    try {
        // Crear tabla si no existe
        const dataset = bigquery.dataset(datasetId);
        const table = dataset.table(tableId);
        
        const [exists] = await table.exists();
        if (!exists) {
            await dataset.createTable(tableId, {
                schema: [
                    { name: 'device_id', type: 'STRING' },
                    { name: 'timestamp', type: 'TIMESTAMP' },
                    { name: 'value', type: 'FLOAT' },
                    { name: 'processed_at', type: 'TIMESTAMP' }
                ]
            });
        }
        
        // Cargar datos a BigQuery
        await table.load(file.name, {
            sourceFormat: 'NEWLINE_DELIMITED_JSON',
            writeDisposition: 'WRITE_APPEND'
        });
        
        console.log(`Successfully loaded ${file.name} to BigQuery`);
    } catch (error) {
        console.error(`Error processing ${file.name}:`, error);
        throw error;
    }
};
