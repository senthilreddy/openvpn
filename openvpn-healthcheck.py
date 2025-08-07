from flask import Flask, Response
import subprocess

app = Flask(__name__)

@app.route('/health')
def health():
    result = subprocess.run(['systemctl', 'is-active', '--quiet', 'openvpn@server'], capture_output=True)
    if result.returncode == 0:
        return Response('OK\n', status=200)
    return Response('OpenVPN down\n', status=503)

app.run(host='0.0.0.0', port=9115)