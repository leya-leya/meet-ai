import os
import sqlite3
import subprocess
import sys
from datetime import datetime
from pathlib import Path

import pytest
from pydantic import ValidationError

import app.db as db
from app.schemas.record import RecordRead


def test_relative_storage_configuration_resolves_from_project_root() -> None:
    project_root = Path(__file__).parents[2]

    assert db.resolve_database_url("sqlite:///./data/app.db") == (
        f"sqlite:///{(project_root / 'data' / 'app.db').as_posix()}"
    )
    assert db.resolve_storage_path("./uploads") == project_root / "uploads"


def record_response_data() -> dict[str, object]:
    return {
        "id": "record-id",
        "title": "测试会议",
        "original_filename": "meeting.mp3",
        "stored_filename": "internal-name.mp3",
        "file_type": ".mp3",
        "file_size": 128,
        "status": "uploaded",
        "transcript": None,
        "summary": None,
        "error_message": None,
        "created_at": datetime(2026, 8, 14, 12, 0, 0),
        "updated_at": datetime(2026, 8, 14, 12, 0, 0),
    }


def test_record_response_does_not_expose_stored_filename() -> None:
    response = RecordRead.model_validate(record_response_data())

    assert "stored_filename" not in response.model_dump()


def test_record_response_rejects_unknown_status() -> None:
    data = record_response_data()
    data["status"] = "unknown"

    with pytest.raises(ValidationError):
        RecordRead.model_validate(data)


@pytest.fixture
def initialized_storage(tmp_path: Path) -> tuple[Path, Path]:
    database_path = tmp_path / "data" / "app.db"
    upload_dir = tmp_path / "uploads"
    env = os.environ.copy()
    env["DATABASE_URL"] = f"sqlite:///{database_path.as_posix()}"
    env["UPLOAD_DIR"] = str(upload_dir)

    result = subprocess.run(
        [
            sys.executable,
            "-c",
            (
                "from fastapi.testclient import TestClient; "
                "from app.main import app; "
                "client = TestClient(app); "
                "client.__enter__(); "
                "client.__exit__(None, None, None)"
            ),
        ],
        cwd=Path(__file__).parents[1],
        env=env,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    return database_path, upload_dir


def test_startup_creates_runtime_directories(
    initialized_storage: tuple[Path, Path],
) -> None:
    database_path, upload_dir = initialized_storage

    assert database_path.parent.is_dir()
    assert upload_dir.is_dir()


def test_startup_creates_records_table(
    initialized_storage: tuple[Path, Path],
) -> None:
    database_path, _ = initialized_storage

    with sqlite3.connect(database_path) as connection:
        columns = {
            row[1] for row in connection.execute("PRAGMA table_info(records)")
        }

    assert columns == {
        "id",
        "title",
        "original_filename",
        "stored_filename",
        "file_type",
        "file_size",
        "status",
        "transcript",
        "summary",
        "error_message",
        "created_at",
        "updated_at",
    }


def test_records_table_rejects_unknown_status(
    initialized_storage: tuple[Path, Path],
) -> None:
    database_path, _ = initialized_storage

    with sqlite3.connect(database_path) as connection:
        with pytest.raises(sqlite3.IntegrityError):
            connection.execute(
                """
                INSERT INTO records (
                    id, title, original_filename, stored_filename,
                    file_type, file_size, status
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    "record-id",
                    "测试会议",
                    "meeting.mp3",
                    "internal-name.mp3",
                    ".mp3",
                    128,
                    "unknown",
                ),
            )
