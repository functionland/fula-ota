import requests
import json
from requests.exceptions import RequestException
import logging

logger = logging.getLogger(__name__)

class GoServerClientError(Exception):
    """Base exception for GoServerClient errors"""
    pass

class GoServerClient:
    def __init__(self, server_address="127.0.0.1:3500", timeout=25):
        self.server_address = server_address
        self.base_url = f"http://{server_address}"
        self.timeout = timeout
        self.session = requests.Session()

    def _make_request(self, method, endpoint, data=None):
        """Make HTTP request with proper error handling"""
        try:
            url = f"{self.base_url}{endpoint}"
            response = self.session.request(
                method=method,
                url=url,
                json=data if method == 'POST' else None,
                data=data if method != 'POST' else None,
                timeout=self.timeout
            )
            response.raise_for_status()
            return response.json()
        except requests.exceptions.ConnectionError as e:
            logger.error(f"Connection error to {url}: {str(e)}")
            return {"error": "Server connection failed", "status": "error"}
        except requests.exceptions.Timeout as e:
            logger.error(f"Timeout connecting to {url}: {str(e)}")
            return {"error": "Request timed out", "status": "error"}
        except requests.exceptions.HTTPError as e:
            logger.error(f"HTTP error from {url}: {str(e)}")
            return {"error": f"Server returned {response.status_code}", "status": "error"}
        except ValueError as e:
            logger.error(f"Invalid JSON response from {url}: {str(e)}")
            return {"error": "Invalid server response", "status": "error"}
        except Exception as e:
            logger.error(f"Unexpected error accessing {url}: {str(e)}")
            return {"error": "Unexpected error", "status": "error"}

    def readiness(self):
        """Get system readiness status"""
        return self._make_request('GET', '/readiness')

    def list_wifi(self):
        """Get list of available WiFi networks"""
        return self._make_request('GET', '/wifi/list')

    def wifi_status(self):
        """Check WiFi connection status"""
        return self._make_request('GET', '/wifi/status')
    
    def properties(self):
        """Get Properties"""
        response = self._make_request('GET', '/properties')
        return response

    def connect_wifi(self, ssid, password):
        """Connect to a WiFi network"""
        data = {
            'ssid': ssid,
            'password': password
        }
        return self._make_request('POST', '/wifi/connect', data)

    def enable_access_point(self):
        """Enable WiFi access point"""
        return self._make_request('GET', '/ap/enable')

    def exchange_peers(self, peer_id, seed):
        """Exchange peer information"""
        data = {
            'peer_id': peer_id,
            'seed': seed
        }
        return self._make_request('POST', '/peer/exchange', data)

    def generate_identity(self, seed):
        """Generate identity from seed"""
        data = {
            'seed': seed
        }
        return self._make_request('POST', '/peer/generate-identity', data)

    def partition(self):
        """Handle partition request"""
        return self._make_request('POST', '/partition')

    def __del__(self):
        """Cleanup session on object destruction"""
        try:
            self.session.close()
        except:
            pass