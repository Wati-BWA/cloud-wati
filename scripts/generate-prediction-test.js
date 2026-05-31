const fetch = require('node-fetch');

async function testPredictionEndpoint() {
  const deviceId = 'test-device-123';
  // Use bypass auth for local/dev testing if API is running with BYPASS_AUTH=true
  // Or replace with valid API key
  const headers = {
    'x-user-id': 'test-user-123',
    'x-api-key': 'test-api-key'
  };

  const url = `http://localhost:8080/api/predictions/${deviceId}/latest`;
  
  console.log(`Testing predictions endpoint: ${url}`);
  try {
    const response = await fetch(url, { headers });
    const data = await response.json();
    console.log('Response:', JSON.stringify(data, null, 2));
  } catch (error) {
    console.error('Error testing endpoint:', error);
  }
}

testPredictionEndpoint();
