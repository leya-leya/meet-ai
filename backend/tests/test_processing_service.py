from pathlib import Path

import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker

from app.db import Base
from app.models.record import Record, RecordStatus
from app.providers.asr.base import ASRProvider
from app.providers.asr.mock import MOCK_TRANSCRIPT, MockASRProvider
from app.providers.llm.base import LLMProvider
from app.providers.llm.mock import MOCK_SUMMARY, MockLLMProvider
from app.services.processing_service import process_record


class StatusTrackingSession(Session):
    committed_statuses: list[RecordStatus]
    fail_once_on_status: RecordStatus | None

    def commit(self) -> None:
        fail_once_on_status = getattr(self, "fail_once_on_status", None)
        if any(
            isinstance(value, Record) and value.status == fail_once_on_status
            for value in self.identity_map.values()
        ):
            self.fail_once_on_status = None
            raise RuntimeError("database write failed")

        super().commit()
        statuses = [
            value.status
            for value in self.identity_map.values()
            if isinstance(value, Record)
        ]
        self.committed_statuses.extend(statuses)


@pytest.fixture
def processing_context(
    tmp_path: Path,
) -> tuple[sessionmaker[StatusTrackingSession], Record, Path]:
    database_path = tmp_path / "test.db"
    media_path = tmp_path / "meeting.mp3"
    media_path.write_bytes(b"test audio")
    engine = create_engine(f"sqlite:///{database_path.as_posix()}")
    testing_session = sessionmaker(bind=engine, class_=StatusTrackingSession)
    Base.metadata.create_all(bind=engine)

    with testing_session() as session:
        session.committed_statuses = []
        record = Record(
            title="测试会议",
            original_filename="meeting.mp3",
            stored_filename="meeting.mp3",
            file_type=".mp3",
            file_size=media_path.stat().st_size,
            status=RecordStatus.UPLOADED,
        )
        session.add(record)
        session.commit()
        record_id = record.id

    with testing_session() as session:
        record = session.get(Record, record_id)
        assert record is not None
        session.expunge(record)

    yield testing_session, record, media_path
    engine.dispose()


def test_mock_providers_return_fixed_local_results(tmp_path: Path) -> None:
    media_path = tmp_path / "sample.wav"
    media_path.write_bytes(b"audio")

    transcript = MockASRProvider().transcribe(str(media_path))
    summary = MockLLMProvider().summarize(transcript)

    assert transcript == "这是一段用于自动化测试的转写文本。"
    assert summary == MOCK_SUMMARY
    assert "## 内容摘要" in summary
    assert "## 核心要点" in summary
    assert "## 待办事项" in summary


def test_processing_persists_outputs_in_required_status_order(
    processing_context: tuple[
        sessionmaker[StatusTrackingSession], Record, Path
    ],
) -> None:
    testing_session, detached_record, media_path = processing_context

    with testing_session() as session:
        session.committed_statuses = []
        record = session.merge(detached_record)

        result = process_record(
            session=session,
            record=record,
            file_path=media_path,
            asr_provider=MockASRProvider(),
            llm_provider=MockLLMProvider(),
        )

        assert result.status == RecordStatus.COMPLETED
        assert result.transcript == MOCK_TRANSCRIPT
        assert result.summary == MOCK_SUMMARY
        assert result.error_message is None
        assert session.committed_statuses == [
            RecordStatus.TRANSCRIBING,
            RecordStatus.TRANSCRIBED,
            RecordStatus.SUMMARIZING,
            RecordStatus.COMPLETED,
        ]


def test_processing_rejects_record_that_is_not_uploaded(
    processing_context: tuple[
        sessionmaker[StatusTrackingSession], Record, Path
    ],
) -> None:
    testing_session, detached_record, media_path = processing_context

    with testing_session() as session:
        session.committed_statuses = []
        record = session.merge(detached_record)
        record.status = RecordStatus.COMPLETED
        session.commit()
        session.committed_statuses = []

        with pytest.raises(
            ValueError,
            match="Record must be uploaded before processing",
        ):
            process_record(
                session=session,
                record=record,
                file_path=media_path,
                asr_provider=MockASRProvider(),
                llm_provider=MockLLMProvider(),
            )

        assert record.status == RecordStatus.COMPLETED
        assert record.error_message is None
        assert session.committed_statuses == []


class FailingASRProvider(ASRProvider):
    def transcribe(self, file_path: str) -> str:
        raise RuntimeError("ASR unavailable")


class FailingLLMProvider(LLMProvider):
    def summarize(self, transcript: str) -> str:
        raise RuntimeError("LLM unavailable")


def test_asr_failure_is_persisted_without_calling_llm(
    processing_context: tuple[
        sessionmaker[StatusTrackingSession], Record, Path
    ],
) -> None:
    testing_session, detached_record, media_path = processing_context

    class UnexpectedLLMProvider(LLMProvider):
        def summarize(self, transcript: str) -> str:
            pytest.fail("LLM must not run after ASR failure")

    with testing_session() as session:
        session.committed_statuses = []
        record = session.merge(detached_record)

        result = process_record(
            session=session,
            record=record,
            file_path=media_path,
            asr_provider=FailingASRProvider(),
            llm_provider=UnexpectedLLMProvider(),
        )

        assert result.status == RecordStatus.FAILED
        assert result.error_message == "ASR unavailable"
        assert result.transcript is None
        assert result.summary is None
        assert session.committed_statuses == [
            RecordStatus.TRANSCRIBING,
            RecordStatus.FAILED,
        ]


def test_llm_failure_keeps_persisted_transcript(
    processing_context: tuple[
        sessionmaker[StatusTrackingSession], Record, Path
    ],
) -> None:
    testing_session, detached_record, media_path = processing_context
    record_id = detached_record.id

    with testing_session() as session:
        session.committed_statuses = []
        record = session.merge(detached_record)

        result = process_record(
            session=session,
            record=record,
            file_path=media_path,
            asr_provider=MockASRProvider(),
            llm_provider=FailingLLMProvider(),
        )

        assert result.status == RecordStatus.FAILED
        assert result.error_message == "LLM unavailable"
        assert result.transcript == MOCK_TRANSCRIPT
        assert result.summary is None
        assert session.committed_statuses == [
            RecordStatus.TRANSCRIBING,
            RecordStatus.TRANSCRIBED,
            RecordStatus.SUMMARIZING,
            RecordStatus.FAILED,
        ]

    with testing_session() as verification_session:
        persisted_record = verification_session.get(Record, record_id)
        assert persisted_record is not None
        assert persisted_record.status == RecordStatus.FAILED
        assert persisted_record.error_message == "LLM unavailable"
        assert persisted_record.transcript == MOCK_TRANSCRIPT
        assert persisted_record.summary is None


def test_completion_commit_failure_keeps_generated_outputs(
    processing_context: tuple[
        sessionmaker[StatusTrackingSession], Record, Path
    ],
) -> None:
    testing_session, detached_record, media_path = processing_context
    record_id = detached_record.id

    with testing_session() as session:
        session.committed_statuses = []
        session.fail_once_on_status = RecordStatus.COMPLETED
        record = session.merge(detached_record)

        result = process_record(
            session=session,
            record=record,
            file_path=media_path,
            asr_provider=MockASRProvider(),
            llm_provider=MockLLMProvider(),
        )

        assert result.status == RecordStatus.FAILED
        assert result.error_message == "database write failed"
        assert result.transcript == MOCK_TRANSCRIPT
        assert result.summary == MOCK_SUMMARY

    with testing_session() as verification_session:
        persisted_record = verification_session.get(Record, record_id)
        assert persisted_record is not None
        assert persisted_record.status == RecordStatus.FAILED
        assert persisted_record.error_message == "database write failed"
        assert persisted_record.transcript == MOCK_TRANSCRIPT
        assert persisted_record.summary == MOCK_SUMMARY
