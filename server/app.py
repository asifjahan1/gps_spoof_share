# pyrefly: ignore [missing-import]
from flask import Flask, request, jsonify
import sys
import threading
# pyrefly: ignore [missing-import]
from pymobiledevice3.__main__ import main as py3main

app = Flask(__name__)

# To prevent blocking the Flask thread if pymobiledevice3 command hangs, we can run it in a separate thread.
def run_pymobiledevice3(args):
    sys.argv = args
    try:
        py3main()
    except SystemExit as e:
        print(f"Command exited with code {e.code}")
    except Exception as e:
        print(f"Exception during command execution: {e}")

@app.route('/set_location', methods=['POST'])
def set_location():
    data = request.json
    lat = data.get('lat')
    lng = data.get('lng')
    
    if lat is None or lng is None:
        return jsonify({"error": "lat and lng are required"}), 400

    print(f"Setting iOS location to {lat}, {lng}")
    
    args = [
        "pymobiledevice3",
        "developer",
        "dvt",
        "simulate-location",
        "set",
        "--tunnel",
        "",
        "--",
        str(lat),
        str(lng)
    ]
    
    # Run in background to avoid blocking response
    t = threading.Thread(target=run_pymobiledevice3, args=(args,))
    t.start()
    
    return jsonify({"status": "Location spoof command sent to device"}), 200

@app.route('/clear_location', methods=['POST'])
def clear_location():
    print("Clearing iOS location")
    args = [
        "pymobiledevice3",
        "developer",
        "dvt",
        "simulate-location",
        "clear",
        "--tunnel",
        ""
    ]
    
    t = threading.Thread(target=run_pymobiledevice3, args=(args,))
    t.start()
    
    return jsonify({"status": "Clear location command sent to device"}), 200

if __name__ == '__main__':
    # Run on all interfaces so the Android phone can connect
    app.run(host='0.0.0.0', port=5000, debug=True)
