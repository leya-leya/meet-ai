from datetime import datetime

from pydantic import BaseModel, ConfigDict, field_validator

from app.models.record import RecordStatus


class RecordRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    title: str
    original_filename: str
    file_type: str
    file_size: int
    status: RecordStatus
    transcript: str | None
    summary: str | None
    error_message: str | None
    created_at: datetime
    updated_at: datetime


class RecordUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    title: str | None = None
    summary: str | None = None
    transcript: str | None = None

    @field_validator("title")
    @classmethod
    def title_must_not_be_empty(cls, value: str | None) -> str:
        if value is None or not value.strip():
            raise ValueError("Title must not be empty")
        return value
