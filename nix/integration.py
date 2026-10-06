"""Exercise real HTTP forms, RabbitMQ deliveries and systemd credentials."""
import re
import json
import subprocess
import time

import pika
import requests

BASE = "http://127.0.0.1:8080"
REST = "http://127.0.0.1:8003"
QUEUE = "missing-barcodes"
SHOPPING_QUEUE = "test-shopping-list"
params = pika.ConnectionParameters(
    "127.0.0.1", credentials=pika.PlainCredentials("bpd", "test-password")
)
browser = requests.Session()


def wait_until(predicate, seconds=60):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            if predicate():
                return
        except (requests.RequestException, pika.exceptions.AMQPError):
            pass
        time.sleep(0.2)
    raise AssertionError("condition not reached")


def broker(action):
    connection = pika.BlockingConnection(params)
    try:
        return action(connection.channel())
    finally:
        connection.close()


def count():
    return broker(lambda ch: ch.queue_declare(queue=QUEUE, passive=True).method.message_count)


def publish(payload):
    broker(lambda ch: ch.basic_publish("", QUEUE, payload, pika.BasicProperties(delivery_mode=2)))


def mode(value):
    requests.post(REST + "/mode", json={"mode": value}, timeout=5).raise_for_status()


def posts():
    return requests.get(REST + "/state", timeout=5).json()["posts"]


def home():
    return browser.get(BASE + "/", timeout=10)


def claim():
    page = home()
    csrf = re.search(r'name="csrf" value="([^"]+)"', page.text).group(1)
    r = browser.post(BASE + "/claim", data={"csrf": csrf}, allow_redirects=False, timeout=10)
    assert r.status_code == 303
    location = r.headers["Location"]
    assert location.startswith("/claim/")
    return location, csrf


def save(location, csrf, description="Milk", shopping=True):
    data = {"csrf": csrf, "description": description}
    if shopping:
        data["addToShoppingList"] = "on"
    return browser.post(BASE + location + "/save", data=data, allow_redirects=False, timeout=20)


def shopping_message():
    return broker(lambda ch: ch.basic_get(queue=SHOPPING_QUEUE, auto_ack=True))


def release(location, csrf):
    r = browser.post(BASE + location + "/return", data={"csrf": csrf}, allow_redirects=False, timeout=10)
    assert r.status_code == 303


broker(lambda ch: ch.queue_declare(queue=QUEUE, durable=True))
broker(lambda ch: ch.queue_declare(queue=SHOPPING_QUEUE, durable=True))
wait_until(lambda: requests.get(BASE + "/readyz", timeout=10).status_code == 200)
assert requests.get(BASE + "/healthz", timeout=5).status_code == 200
assert requests.post(BASE + "/claim", timeout=5).status_code == 403
# Empty queue stays empty, with no accidental reads from a GET.
page = home()
csrf = re.search(r'name="csrf" value="([^"]+)"', page.text).group(1)
assert browser.post(BASE + "/claim", data={"csrf": csrf}, timeout=10).status_code == 200
assert "The queue is empty" in home().text
publish("000786534249")
location, csrf = claim()
assert "000786534249" in browser.get(BASE + location, timeout=10).text
assert count() == 0  # The sole barcode is unacknowledged, not ready.
assert save(location, csrf, "Café milk").status_code == 303
assert posts()[-1] == {"barcode": "000786534249", "description": "Café milk"}
method, properties, payload = shopping_message()
assert method is not None
assert properties.content_type == "application/json" and properties.delivery_mode == 2
assert json.loads(payload) == {"barcode": "000786534249", "description": "Café milk"}
assert browser.get(BASE + location, timeout=10).status_code == 410
assert save(location, csrf).status_code == 303
assert len(posts()) == 1  # Double submission never writes again.
assert count() == 0
# Unchecking the form still saves the backend product, without publishing.
publish("0000000")
location, csrf = claim()
page = browser.get(BASE + location, timeout=10).text
assert 'name="addToShoppingList" value="on" checked' in page
assert save(location, csrf, "Apples", shopping=False).headers["Location"] == "/"
assert posts()[-1] == {"barcode": "0000000", "description": "Apples"}
assert shopping_message()[0] is None
# A missing shopping queue keeps the claim and retries only publication.
broker(lambda ch: ch.queue_delete(queue=SHOPPING_QUEUE))
publish("0000001")
location, csrf = claim()
previous = len(posts())
assert save(location, csrf, "  Pears  ").headers["Location"] == location
assert len(posts()) == previous + 1
page = browser.get(BASE + location, timeout=10).text
assert "Product saved, but adding it to the shopping list" in page
assert "readonly" in page
broker(lambda ch: ch.queue_declare(queue=SHOPPING_QUEUE, durable=True))
assert save(location, csrf, "Pears").headers["Location"] == "/"
assert len(posts()) == previous + 1
assert json.loads(shopping_message()[2]) == {"barcode": "0000001", "description": "Pears"}
# Dropping unknown codes removes deliveries without writing products.
publish("unknown")
location, csrf = claim()
previous = len(posts())
assert "Drop barcode" in browser.get(BASE + location, timeout=10).text
assert browser.post(BASE + location + "/drop", timeout=10).status_code == 403
r = browser.post(BASE + location + "/drop", data={"csrf": csrf}, allow_redirects=False, timeout=10)
assert r.status_code == 303 and r.headers["Location"] == "/"
assert browser.get(BASE + location, timeout=10).status_code == 410
assert count() == 0 and len(posts()) == previous
# Non-2xx responses preserve the claim and escaped input, with no automatic retry.
mode("error")
publish("9999")
location, csrf = claim()
r = save(location, csrf, "<script>milk</script>")
assert r.status_code == 303 and r.headers["Location"] == location
page = browser.get(BASE + location, timeout=10)
assert "HTTP 500" in page.text and "&lt;script&gt;milk&lt;/script&gt;" in page.text
assert shopping_message()[0] is None
release(location, csrf)
assert count() == 1
# Background expiry returns abandoned work; old forms cannot post it.
location, csrf = claim()
previous = len(posts())
wait_until(lambda: count() == 1)
assert save(location, csrf).status_code == 303
assert len(posts()) == previous
# Broker disconnect invalidates the claim and recovers the unacknowledged delivery.
location, csrf = claim()
subprocess.run(["runuser", "-u", "rabbitmq", "--", "rabbitmqctl", "close_all_connections", "bpd integration disconnect"], check=True)
wait_until(lambda: browser.get(BASE + location, timeout=10).status_code == 410)
wait_until(lambda: requests.get(BASE + "/readyz", timeout=10).status_code == 200)
assert count() == 1
# A process killed while holding a delivery cannot lose it.
location, csrf = claim()
subprocess.run(["systemctl", "kill", "--signal=SIGKILL", "bpd"], check=True)
wait_until(lambda: count() == 1)
wait_until(lambda: requests.get(BASE + "/readyz", timeout=10).status_code == 200)
# A slow save completes even when the claim TTL passes during the request.
mode("slow")
location, csrf = claim()
time.sleep(7)
assert save(location, csrf).headers["Location"] == "/"
assert count() == 0
# A connection dropped after receiving the POST cannot acknowledge the message.
mode("disconnect")
publish("5678")
location, csrf = claim()
previous = len(posts())
assert save(location, csrf).headers["Location"] == location
assert len(posts()) == previous + 1
assert "response was lost" in browser.get(BASE + location, timeout=10).text
release(location, csrf)
assert count() == 1
mode("ok")
location, csrf = claim()
assert save(location, csrf).headers["Location"] == "/"
# HTTP timeouts cannot acknowledge or silently retry a product write.
mode("timeout")
publish("1234")
location, csrf = claim()
previous = len(posts())
assert save(location, csrf).status_code == 303
wait_until(lambda: count() == 1)
assert len(posts()) == previous + 1
# Invalid UTF-8 is visible and remains recoverable.
broker(lambda ch: ch.queue_purge(queue=QUEUE))
mode("ok")
publish(b"\xff")
location, csrf = claim()
page = browser.get(BASE + location, timeout=10).text
assert "not UTF-8" in page and "Save product" not in page
release(location, csrf)
assert count() == 1
location, csrf = claim()
previous = len(posts())
assert browser.post(BASE + location + "/drop", data={"csrf": csrf}, allow_redirects=False, timeout=10).status_code == 303
assert count() == 0 and len(posts()) == previous
# Secrets are delivered to the dynamic user rather than embedded in ExecStart.
unit = subprocess.check_output(["systemctl", "cat", "bpd"], text=True)
assert "LoadCredential=" in unit and "test-password" not in unit
print("BPD integration scenarios passed")
