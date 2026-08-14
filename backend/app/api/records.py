from fastapi import APIRouter, Depends, File, HTTPException, UploadFile, status
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

import app.db as db
from app.schemas.record import RecordRead
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
