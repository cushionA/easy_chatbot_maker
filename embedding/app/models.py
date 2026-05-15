from typing import Literal

from pydantic import BaseModel, Field

EmbedMode = Literal["query", "passage"]


class EmbedRequest(BaseModel):
    text: str = Field(min_length=1, max_length=8000)
    mode: EmbedMode = "query"


class EmbedBatchRequest(BaseModel):
    texts: list[str] = Field(min_length=1, max_length=64)
    mode: EmbedMode = "passage"


class EmbedResponse(BaseModel):
    embedding: list[float]
    dim: int
    model: str


class EmbedBatchResponse(BaseModel):
    embeddings: list[list[float]]
    dim: int
    model: str


class HealthResponse(BaseModel):
    status: str
    model: str
    dim: int
