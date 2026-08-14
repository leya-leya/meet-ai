from fastapi import APIRouter, Depends, File, HTTPException, UploadFile, status
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

import app.db as db
from app.models.record import Record, RecordStatus
from app.providers.asr.mock import MockASRProvider
from app.providers.llm.mock import MockLLMProvider
from app.schemas.record import RecordRead
from app.services.processing_service import process_record
from app.services.record_service import (
    FileTooLargeError,
    UnsupportedFileTypeError,
    create_record,
    max_upload_bytes,
)


router = APIRouter(prefix="/records", tags=["records"])


@router.post("", response_model=RecordRead, status_code=status.HTTP_201_CREATED)
def upload_record(
    file: UploadFile = File(...),
    session: Session = Depends(db.get_db),
) -> RecordRead:
    try:
        record = create_record(
            session=session,
            upload=file,
            upload_dir=db.UPLOAD_DIR,
            maximum_bytes=max_upload_bytes(),
        )
    except UnsupportedFileTypeError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except FileTooLargeError as exc:
        raise HTTPException(status_code=413, detail=str(exc)) from exc
    except OSError as exc:
        raise HTTPException(status_code=500, detail="Failed to save uploaded file") from exc
    except SQLAlchemyError as exc:
        raise HTTPException(status_code=500, detail="Failed to save record") from exc
    finally:
        file.file.close()

    return RecordRead.model_validate(record)


@router.post("/{record_id}/process", response_model=RecordRead)
def process_uploaded_record(
    record_id: str,
    session: Session = Depends(db.get_db),
) -> RecordRead:
    record = session.get(Record, record_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Record not found")

    file_path = db.UPLOAD_DIR / record.stored_filename
    if not file_path.is_file():
        error_detail = "Uploaded media file not found"
        record.status = RecordStatus.FAILED
        record.error_message = error_detail
        session.commit()
        raise HTTPException(
            status_code=404,
            detail=error_detail,
        )

    processed_record = process_record(
        session=session,
        record=record,
        file_path=file_path,
        asr_provider=MockASRProvider(),
        llm_provider=MockLLMProvider(),
    )
    return RecordRead.model_validate(processed_record)
