from fastapi import FastAPI, HTTPException

from .embedder import get_embedder
from .models import (
    EmbedBatchRequest,
    EmbedBatchResponse,
    EmbedRequest,
    EmbedResponse,
    HealthResponse,
)

app = FastAPI(title="Portfolio Embedding Service", version="0.1.0")


@app.get("/healthz", response_model=HealthResponse)
def healthz() -> HealthResponse:
    e = get_embedder()
    return HealthResponse(status="ok", model=e.model_name, dim=e.dim)


@app.post("/embed", response_model=EmbedResponse)
def embed(req: EmbedRequest) -> EmbedResponse:
    e = get_embedder()
    vec = e.embed([req.text], mode=req.mode)[0]
    return EmbedResponse(embedding=vec, dim=len(vec), model=e.model_name)


@app.post("/embed/batch", response_model=EmbedBatchResponse)
def embed_batch(req: EmbedBatchRequest) -> EmbedBatchResponse:
    if any(not t.strip() for t in req.texts):
        raise HTTPException(status_code=400, detail="empty text in batch")
    e = get_embedder()
    vecs = e.embed(req.texts, mode=req.mode)
    return EmbedBatchResponse(embeddings=vecs, dim=len(vecs[0]), model=e.model_name)
