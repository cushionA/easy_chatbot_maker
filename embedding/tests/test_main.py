from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_healthz_ok():
    resp = client.get("/healthz")
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "ok"
    assert body["dim"] > 0


def test_embed_returns_vector():
    resp = client.post("/embed", json={"text": "印刷ができません"})
    assert resp.status_code == 200
    body = resp.json()
    assert body["dim"] == len(body["embedding"])
    assert body["dim"] > 0


def test_embed_rejects_empty():
    resp = client.post("/embed", json={"text": ""})
    assert resp.status_code == 422


def test_batch_rejects_blank_item():
    resp = client.post("/embed/batch", json={"texts": ["ok", "   "]})
    assert resp.status_code == 400


def test_batch_returns_vectors():
    resp = client.post("/embed/batch", json={"texts": ["a", "b", "c"]})
    assert resp.status_code == 200
    body = resp.json()
    assert len(body["embeddings"]) == 3
    assert all(len(v) == body["dim"] for v in body["embeddings"])
