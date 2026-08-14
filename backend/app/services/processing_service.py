from pathlib import Path

from sqlalchemy.orm import Session

from app.models.record import Record, RecordStatus
from app.providers.asr.base import ASRProvider
from app.providers.llm.base import LLMProvider


def _save_status(
    session: Session,
    record: Record,
    status: RecordStatus,
) -> None:
    record.status = status
    session.commit()
    session.refresh(record)


def process_record(
    *,
    session: Session,
    record: Record,
    file_path: str | Path,
    asr_provider: ASRProvider,
    llm_provider: LLMProvider,
) -> Record:
    if record.status != RecordStatus.UPLOADED:
        raise ValueError("Record must be uploaded before processing")

    record.error_message = None
    generated_transcript: str | None = None
    generated_summary: str | None = None

    try:
        _save_status(session, record, RecordStatus.TRANSCRIBING)

        generated_transcript = asr_provider.transcribe(str(file_path))
        record.transcript = generated_transcript
        _save_status(session, record, RecordStatus.TRANSCRIBED)

        _save_status(session, record, RecordStatus.SUMMARIZING)
        generated_summary = llm_provider.summarize(generated_transcript)
        record.summary = generated_summary
        _save_status(session, record, RecordStatus.COMPLETED)
    except Exception as exc:
        session.rollback()
        if generated_transcript is not None:
            record.transcript = generated_transcript
        if generated_summary is not None:
            record.summary = generated_summary
        record.status = RecordStatus.FAILED
        record.error_message = str(exc) or exc.__class__.__name__
        session.commit()
        session.refresh(record)

    return record
