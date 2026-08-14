from datetime import datetime

from pydantic import BaseModel, ConfigDict

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
