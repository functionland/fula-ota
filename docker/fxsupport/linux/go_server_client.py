import requests
import json
from requests.exceptions import RequestException
import logging
from urllib.parse import urlencode

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
        try:
            url = f"{self.base_url}{endpoint}"
            headers = {'Content-Type': 'application/x-www-form-urlencoded'}
            
            # For POST with form data, ensure it's properly encoded
            if method == 'POST' and data:
                encoded_data = urlencode(data)
            else:
                encoded_data = data
                
            response = self.session.request(
                method=method,
                url=url,
                data=encoded_data,
                headers=headers,
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
        return {
            "bloxFreeSpace": {
                "device_count": response.get("bloxFreeSpace", {}).get("device_count", 0),
                "size": response.get("bloxFreeSpace", {}).get("size", 0),
                "used": response.get("bloxFreeSpace", {}).get("used", 0),
                "avail": response.get("bloxFreeSpace", {}).get("avail", 0),
                "used_percentage": response.get("bloxFreeSpace", {}).get("used_percentage", 0)
            },
            "containerInfo_fula": {},
            "containerInfo_fxsupport": {},
            "containerInfo_node": {},
            "hardwareID": response.get("hardwareID", ""),
            "ota_version": response.get("ota_version", ""),
            "restartNeeded": response.get("restartNeeded", "false")
        }

    def connect_wifi(self, ssid, password, country_code='US'):
        """Connect to a WiFi network"""
        data = {
            'ssid': ssid,
            'password': password,
            'countryCode': country_code
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