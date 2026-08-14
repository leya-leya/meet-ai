import os
from pathlib import Path
from uuid import uuid4

from fastapi import UploadFile
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from app.models.record import Record, RecordStatus


SUPPORTED_EXTENSIONS = {".mp3", ".wav", ".m4a", ".mp4", ".mov"}
UPLOAD_CHUNK_SIZE = 1024 * 1024


class UnsupportedFileTypeError(ValueError):
    pass


class FileTooLargeError(ValueError):
    pass


def max_upload_bytes() -> int:
    return int(os.getenv("MAX_UPLOAD_MB", "500")) * 1024 * 1024


def create_record(
    *,
    session: Session,
    upload: UploadFile,
    upload_dir: Path,
    maximum_bytes: int,
) -> Record:
    original_filename = upload.filename or ""
    extension = Path(original_filename).suffix.lower()
    if extension not in SUPPORTED_EXTENSIONS:
        raise UnsupportedFileTypeError(f"Unsupported file type: {extension}")

    stored_filename = f"{uuid4()}{extension}"
    stored_path = upload_dir / stored_filename
    upload_dir.mkdir(parents=True, exist_ok=True)
    file_size = 0

    try:
        with stored_path.open("xb") as destination:
            while chunk := upload.file.read(UPLOAD_CHUNK_SIZE):
                file_size += len(chunk)
                if file_size > maximum_bytes:
                    raise FileTooLargeError(
                        "File exceeds maximum size of "
                        f"{maximum_bytes // (1024 * 1024)} MB"
                    )
                destination.write(chunk)

        record = Record(
            title=Path(original_filename).stem,
            original_filename=original_filename,
            stored_filename=stored_filename,
            file_type=extension,
            file_size=file_size,
            status=RecordStatus.UPLOADED,
        )
        session.add(record)
        session.commit()
        session.refresh(record)
        return record
    except (FileTooLargeError, OSError, SQLAlchemyError):
        session.rollback()
        stored_path.unlink(missing_ok=True)
        raise
