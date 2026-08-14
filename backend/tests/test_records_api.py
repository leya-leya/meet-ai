from collections.abc import Iterator
from pathlib import Path
from uuid import UUID

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session, sessionmaker

import app.db as db
from app.main import app
from app.models.record import Record, RecordStatus
from app.providers.asr.mock import MOCK_TRANSCRIPT
from app.providers.llm.mock import MOCK_SUMMARY


@pytest.fixture
def record_api(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> Iterator[tuple[TestClient, sessionmaker[Session], Path]]:
    database_path = tmp_path / "test.db"
    upload_dir = tmp_path / "uploads"
    engine = create_engine(
        f"sqlite:///{database_path.as_posix()}",
        connect_args={"check_same_thread": False},
    )
    testing_session = sessionmaker(
        bind=engine,
        autoflush=False,
        autocommit=False,
    )
    db.Base.metadata.create_all(bind=engine)
    monkeypatch.setattr(db, "engine", engine)
    monkeypatch.setattr(db, "SessionLocal", testing_session)
    monkeypatch.setattr(db, "UPLOAD_DIR", upload_dir)

    with TestClient(app, raise_server_exceptions=False) as client:
        yield client, testing_session, upload_dir

    engine.dispose()


@pytest.mark.parametrize("extension", [".mp3", ".wav", ".m4a", ".mp4", ".mov"])
def test_supported_media_upload_creates_uploaded_record_and_file(
    record_api: tuple[TestClient, sessionmaker[Session], Path],
    extension: str,
) -> None:
    client, testing_session, upload_dir = record_api
    original_filename = f"周会记录{extension}"
    content = b"test-media-content"

    response = client.post(
        "/api/records",
        files={"file": (original_filename, content, "application/octet-stream")},
    )

    assert response.status_code == 201
    assert response.json() == {
        "id": response.json()["id"],
        "title": "周会记录",
        "original_filename": original_filename,
        "file_type": extension,
        "file_size": len(content),
        "status": "uploaded",
        "transcript": None,
        "summary": None,
        "error_message": None,
        "created_at": response.json()["created_at"],
        "updated_at": response.json()["updated_at"],
    }

    with testing_session() as session:
        record = session.scalar(select(Record))
        assert record is not None
        assert record.status == RecordStatus.UPLOADED
        assert record.original_filename == original_filename
        assert record.stored_filename.endswith(extension)
        assert str(UUID(Path(record.stored_filename).stem)) == Path(
            record.stored_filename
        ).stem
        assert (upload_dir / record.stored_filename).read_bytes() == content


@pytest.mark.parametrize("filename", ["notes.txt", "program.exe"])
def test_unsupported_extension_returns_400_without_side_effects(
    record_api: tuple[TestClient, sessionmaker[Session], Path],
    filename: str,
) -> None:
    client, testing_session, upload_dir = record_api

    response = client.post(
        "/api/records",
        files={"file": (filename, b"not-media", "application/octet-stream")},
    )

    assert response.status_code == 400
    assert response.json() == {
        "detail": f"Unsupported file type: {Path(filename).suffix}"
    }
    assert not list(upload_dir.glob("*"))
    with testing_session() as session:
        assert session.scalar(select(Record)) is None


def test_same_original_filename_uses_distinct_internal_files(
    record_api: tuple[TestClient, sessionmaker[Session], Path],
) -> None:
    client, testing_session, upload_dir = record_api

    first = client.post(
        "/api/records",
        files={"file": ("meeting.mp3", b"first", "audio/mpeg")},
    )
    second = client.post(
        "/api/records",
        files={"file": ("meeting.mp3", b"second", "audio/mpeg")},
    )

    assert first.status_code == 201
    assert second.status_code == 201
    assert first.json()["id"] != second.json()["id"]
    with testing_session() as session:
        records = list(session.scalars(select(Record).order_by(Record.created_at)))
        assert len(records) == 2
        assert {record.original_filename for record in records} == {"meeting.mp3"}
        assert len({record.stored_filename for record in records}) == 2
        assert {(upload_dir / record.stored_filename).read_bytes() for record in records} == {
            b"first",
            b"second",
        }


def test_filename_stem_is_used_as_default_title(
    record_api: tuple[TestClient, sessionmaker[Session], Path],
) -> None:
    client, _, _ = record_api

    response = client.post(
        "/api/records",
        files={"file": ("weekly.review.mp4", b"video", "video/mp4")},
    )

    assert response.status_code == 201
    assert response.json()["title"] == "weekly.review"
    assert response.json()["original_filename"] == "weekly.review.mp4"


def test_oversized_upload_returns_413_and_removes_partial_file(
    record_api: tuple[TestClient, sessionmaker[Session], Path],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client, testing_session, upload_dir = record_api
    monkeypatch.setenv("MAX_UPLOAD_MB", "0")

    response = client.post(
        "/api/records",
        files={"file": ("too-large.mp3", b"x", "audio/mpeg")},
    )

    assert response.status_code == 413
    assert response.json() == {"detail": "File exceeds maximum size of 0 MB"}
    assert not list(upload_dir.glob("*"))
    with testing_session() as session:
        assert session.scalar(select(Record)) is None


def test_upload_exactly_at_configured_limit_succeeds(
    record_api: tuple[TestClient, sessionmaker[Session], Path],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client, _, _ = record_api
    monkeypatch.setenv("MAX_UPLOAD_MB", "1")
    content = b"x" * (1024 * 1024)

    response = client.post(
        "/api/records",
        files={"file": ("at-limit.mp3", content, "audio/mpeg")},
    )

    assert response.status_code == 201
    assert response.json()["file_size"] == 1024 * 1024


def test_missing_file_returns_validation_error(
    record_api: tuple[TestClient, sessionmaker[Session], Path],
) -> None:
    client, _, _ = record_api

    response = client.post("/api/records")

    assert response.status_code == 422


def test_database_failure_returns_clear_error_and_removes_saved_file(
    record_api: tuple[TestClient, sessionmaker[Session], Path],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client, testing_session, upload_dir = record_api

    class FailingCommitSession(Session):
        def commit(self) -> None:
            raise SQLAlchemyError("database unavailable")

    failing_session = sessionmaker(
        bind=testing_session.kw["bind"],
        class_=FailingCommitSession,
        autoflush=False,
        autocommit=False,
    )
    monkeypatch.setattr(db, "SessionLocal", failing_session)

    response = client.post(
        "/api/records",
        files={"file": ("meeting.mp3", b"audio", "audio/mpeg")},
    )

    assert response.status_code == 500
    assert response.json() == {"detail": "Failed to save record"}
    assert not list(upload_dir.glob("*"))


def test_process_uploaded_record_returns_and_persists_completed_record(
    record_api: tuple[TestClient, sessionmaker[Session], Path],
) -> None:
    client, testing_session, _ = record_api
    upload_response = client.post(
        "/api/records",
        files={"file": ("meeting.mp3", b"audio", "audio/mpeg")},
    )
    record_id = upload_response.json()["id"]

    response = client.post(f"/api/records/{record_id}/process")

    assert response.status_code == 200
    assert response.json() == {
        "id": record_id,
        "title": "meeting",
        "original_filename": "meeting.mp3",
        "file_type": ".mp3",
        "file_size": 5,
        "status": "completed",
        "transcript": MOCK_TRANSCRIPT,
        "summary": MOCK_SUMMARY,
        "error_message": None,
        "created_at": response.json()["created_at"],
        "updated_at": response.json()["updated_at"],
    }

    with testing_session() as session:
        record = session.get(Record, record_id)
        assert record is not None
        assert record.status == RecordStatus.COMPLETED
        assert record.transcript == MOCK_TRANSCRIPT
        assert record.summary == MOCK_SUMMARY
        assert record.error_message is None


def test_process_unknown_record_returns_404(
    record_api: tuple[TestClient, sessionmaker[Session], Path],
) -> None:
    client, _, _ = record_api

    response = client.post("/api/records/missing-record/process")

    assert response.status_code == 404
    assert response.json() == {"detail": "Record not found"}


def test_process_record_with_missing_local_file_returns_clear_error(
    record_api: tuple[TestClient, sessionmaker[Session], Path],
) -> None:
    client, testing_session, upload_dir = record_api
    upload_response = client.post(
        "/api/records",
        files={"file": ("meeting.mp3", b"audio", "audio/mpeg")},
    )
    record_id = upload_response.json()["id"]

    with testing_session() as session:
        record = session.get(Record, record_id)
        assert record is not None
        (upload_dir / record.stored_filename).unlink()

    response = client.post(f"/api/records/{record_id}/process")

    assert response.status_code == 404
    assert response.json() == {"detail": "Uploaded media file not found"}
    with testing_session() as session:
        record = session.get(Record, record_id)
        assert record is not None
        assert record.status == RecordStatus.FAILED
        assert record.transcript is None
        assert record.summary is None
        assert record.error_message == "Uploaded media file not found"
