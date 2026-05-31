import functions_framework
import json
from datetime import datetime

@functions_framework.http
def handler(request):
    """HTTP Cloud Function."""
    request_json = request.get_json(silent=True)
    
    response = {
        'status': 'success',
        'function': __name__,
        'timestamp': datetime.now().isoformat(),
        'message': f'Function executed at {datetime.now()}'
    }
    
    if request_json:
        response['input'] = request_json
    
    return json.dumps(response), 200, {'Content-Type': 'application/json'}
