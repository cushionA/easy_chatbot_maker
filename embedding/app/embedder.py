import os
from functools import lru_cache
from typing import Any

import numpy as np

DEFAULT_MODEL = "intfloat/multilingual-e5-base"


class Embedder:
    """Lazy wrapper around sentence-transformers. In tests/CI use FAKE_EMBEDDER=1
    to avoid downloading the model."""

    def __init__(self, model_name: str, device: str = "cpu") -> None:
        self.model_name = model_name
        self.device = device
        self._fake = os.environ.get("FAKE_EMBEDDER") == "1"
        self._model: Any = None
        self._dim: int | None = 768 if self._fake else None

    def _ensure_loaded(self) -> None:
        if self._fake or self._model is not None:
            return
        from sentence_transformers import SentenceTransformer

        self._model = SentenceTransformer(self.model_name, device=self.device)
        self._dim = int(self._model.get_sentence_embedding_dimension())

    @property
    def dim(self) -> int:
        self._ensure_loaded()
        if self._dim is None:
            raise RuntimeError("Embedder dimension is unknown — model load failed.")
        return self._dim

    def embed(self, texts: list[str], mode: str = "query") -> list[list[float]]:
        if mode not in ("query", "passage"):
            raise ValueError(f"mode must be 'query' or 'passage', got {mode!r}")
        if self._fake:
            return [self._fake_vec(t) for t in texts]
        self._ensure_loaded()
        if self._model is None:
            raise RuntimeError("Embedder model failed to load.")
        prefixed = [f"{mode}: {t}" for t in texts]
        vecs = self._model.encode(prefixed, normalize_embeddings=True)
        return [list(v) for v in vecs]

    def _fake_vec(self, text: str) -> list[float]:
        rng = np.random.default_rng(abs(hash(text)) % (2**32))
        v = rng.standard_normal(self._dim or 768)
        v = v / (np.linalg.norm(v) + 1e-12)
        return [float(x) for x in v.astype(np.float32)]


@lru_cache(maxsize=1)
def get_embedder() -> Embedder:
    name = os.environ.get("EMBEDDING_MODEL", DEFAULT_MODEL)
    device = os.environ.get("EMBEDDING_DEVICE", "cpu")
    return Embedder(name, device)
