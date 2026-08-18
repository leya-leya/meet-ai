from urllib.parse import quote

from fastapi import (
    APIRouter,
    Depends,
    File,
    HTTPException,
    Response,
    UploadFile,
    status,
)
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

import app.db as db
from app.models.record import Record, RecordStatus
from app.providers.asr.base import ASRProviderError
from app.providers.asr.factory import get_asr_provider
from app.providers.llm.base import LLMProviderError
from app.providers.llm.factory import get_llm_provider
from app.schemas.record import RecordRead, RecordUpdate
from app.services.export_service import (
    build_download_filename,
    generate_markdown,
    generate_txt,
)
from app.services.processing_service import process_record
from app.services.record_service import (
    FileTooLargeError,
    UnsupportedFileTypeError,
    create_record,
    delete_record,
    get_record,
    list_records,
    max_upload_bytes,
    update_record,
)


router = APIRouter(prefix="/records", tags=["records"])


def _get_record_or_404(*, session: Session, record_id: str) -> Record:
    record = get_record(session=session, record_id=record_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Record not found")
    return record


def _download_response(
    *,
    content: str,
    media_type: str,
    filename: str,
) -> Response:
    extension = filename.rsplit(".", maxsplit=1)[-1]
    headers = {
        "Content-Disposition": (
            f"attachment; filename=record.{extension}; "
            f"filename*=UTF-8''{quote(filename)}"
        )
    }
    return Response(content=content, media_type=media_type, headers=headers)


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

    try:
        asr_provider = get_asr_provider()
        llm_provider = get_llm_provider()
    except (ASRProviderError, LLMProviderError) as exc:
        record.status = RecordStatus.FAILED
        record.error_message = str(exc)
        session.commit()
        session.refresh(record)
        return RecordRead.model_validate(record)

    processed_record = process_record(
        session=session,
        record=record,
        file_path=file_path,
        asr_provider=asr_provider,
        llm_provider=llm_provider,
    )
    return RecordRead.model_validate(processed_record)


@router.get("", response_model=list[RecordRead])
def list_record_history(
    q: str | None = None,
    session: Session = Depends(db.get_db),
) -> list[RecordRead]:
    records = list_records(session=session, query=q)
    return [RecordRead.model_validate(record) for record in records]


@router.get("/{record_id}", response_model=RecordRead)
def get_record_detail(
    record_id: str,
    session: Session = Depends(db.get_db),
) -> RecordRead:
    record = _get_record_or_404(session=session, record_id=record_id)
    return RecordRead.model_validate(record)


@router.get("/{record_id}/export/txt")
def export_record_as_txt(
    record_id: str,
    session: Session = Depends(db.get_db),
) -> Response:
    record = _get_record_or_404(session=session, record_id=record_id)
    return _download_response(
        content=generate_txt(record),
        media_type="text/plain",
        filename=build_download_filename(record.title, "txt"),
    )


@router.get("/{record_id}/export/md")
def export_record_as_markdown(
    record_id: str,
    session: Session = Depends(db.get_db),
) -> Response:
    record = _get_record_or_404(session=session, record_id=record_id)
    return _download_response(
        content=generate_markdown(record),
        media_type="text/markdown",
        filename=build_download_filename(record.title, "md"),
    )


@router.patch("/{record_id}", response_model=RecordRead)
def edit_record(
    record_id: str,
    payload: RecordUpdate,
    session: Session = Depends(db.get_db),
) -> RecordRead:
    record = _get_record_or_404(session=session, record_id=record_id)
    try:
        updated_record = update_record(
            session=session,
            record=record,
            changes=payload.model_dump(exclude_unset=True),
        )
    except SQLAlchemyError as exc:
        raise HTTPException(
            status_code=500,
            detail="Failed to update record",
        ) from exc
    return RecordRead.model_validate(updated_record)


@router.delete("/{record_id}", status_code=status.HTTP_204_NO_CONTENT)
def remove_record(
    record_id: str,
    session: Session = Depends(db.get_db),
) -> Response:
    record = _get_record_or_404(session=session, record_id=record_id)
    try:
        delete_record(
            session=session,
            record=record,
            upload_dir=db.UPLOAD_DIR,
        )
    except OSError as exc:
        raise HTTPException(
            status_code=500,
            detail="Failed to delete uploaded file",
        ) from exc
    except SQLAlchemyError as exc:
        raise HTTPException(
            status_code=500,
            detail="Failed to delete record",
        ) from exc
    return Response(status_code=status.HTTP_204_NO_CONTENT)
