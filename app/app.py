import os
from flask import Flask
from prometheus_client import Counter, generate_latest, CONTENT_TYPE_LATEST

app = Flask(__name__)
REQUESTS = Counter("app_requests_total", "Total HTTP requests")

@app.route("/")
def index():
    REQUESTS.inc()
    return "hello from the lab\n"

@app.route("/metrics")
def metrics():
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}

if __name__ == "__main__":
    # BIND_HOST is deliberately configurable — Break #1 uses it.
    app.run(host=os.getenv("BIND_HOST", "0.0.0.0"), port=8080)

