from collections.abc import Iterator
from datetime import datetime
from pathlib import Path
from urllib.parse import quote

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker

import app.db as db
from app.main import app
from app.models.record import Record, RecordStatus
from app.services.export_service import (
    build_download_filename,
    generate_markdown,
    generate_txt,
)


@pytest.fixture
def completed_record() -> Record:
    return Record(
        id="record-id",
        title="测试/会议",
        original_filename="原始录音.mp3",
        stored_filename="stored.mp3",
        file_type=".mp3",
        file_size=5,
        status=RecordStatus.COMPLETED,
        summary="这是 AI 摘要。",
        transcript="这是完整转写。",
        created_at=datetime(2026, 8, 15, 10, 30, 0),
        updated_at=datetime(2026, 8, 15, 10, 30, 0),
    )


@pytest.fixture
def export_api(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    completed_record: Record,
) -> Iterator[tuple[TestClient, str]]:
    engine = create_engine(
        f"sqlite:///{(tmp_path / 'test.db').as_posix()}",
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

    with testing_session() as session:
        session.add(completed_record)
        session.commit()
        record_id = completed_record.id

    with TestClient(app, raise_server_exceptions=False) as client:
        yield client, record_id

    engine.dispose()


def test_generate_txt_contains_all_required_record_content(
    completed_record: Record,
) -> None:
    content = generate_txt(completed_record)

    assert content == (
        "测试/会议\n"
        "创建时间：2026-08-15 10:30:00\n"
        "原始文件名：原始录音.mp3\n\n"
        "AI 摘要\n"
        "====================\n\n"
        "这是 AI 摘要。\n\n"
        "完整转写\n"
        "====================\n\n"
        "这是完整转写。\n"
    )


def test_generate_markdown_contains_all_required_record_content(
    completed_record: Record,
) -> None:
    content = generate_markdown(completed_record)

    assert content == (
        "# 测试/会议\n\n"
        "- 创建时间：2026-08-15 10:30:00\n"
        "- 原始文件名：原始录音.mp3\n\n"
        "## AI 摘要\n\n"
        "这是 AI 摘要。\n\n"
        "## 完整转写\n\n"
        "这是完整转写。\n"
    )


@pytest.mark.parametrize(
    ("extension", "expected"),
    [("txt", "测试_会议.txt"), ("md", "测试_会议.md")],
)
def test_build_download_filename_replaces_unsafe_characters(
    extension: str,
    expected: str,
) -> None:
    assert build_download_filename("测试/会议", extension) == expected


@pytest.mark.parametrize(
    ("extension", "content_type", "expected_heading"),
    [
        ("txt", "text/plain; charset=utf-8", "AI 摘要"),
        ("md", "text/markdown; charset=utf-8", "## AI 摘要"),
    ],
)
def test_export_api_returns_utf8_download_with_correct_filename(
    export_api: tuple[TestClient, str],
    extension: str,
    content_type: str,
    expected_heading: str,
) -> None:
    client, record_id = export_api

    response = client.get(f"/api/records/{record_id}/export/{extension}")

    expected_filename = f"测试_会议.{extension}"
    assert response.status_code == 200
    assert response.headers["content-type"] == content_type
    assert response.headers["content-disposition"] == (
        f"attachment; filename=record.{extension}; "
        f"filename*=UTF-8''{quote(expected_filename)}"
    )
    assert "测试/会议" in response.text
    assert "2026-08-15 10:30:00" in response.text
    assert "原始录音.mp3" in response.text
    assert expected_heading in response.text
    assert "这是 AI 摘要。" in response.text
    assert "这是完整转写。" in response.text


@pytest.mark.parametrize("extension", ["txt", "md"])
def test_export_unknown_record_returns_404(
    export_api: tuple[TestClient, str],
    extension: str,
) -> None:
    client, _ = export_api

    response = client.get(f"/api/records/missing-record/export/{extension}")

    assert response.status_code == 404
    assert response.json() == {"detail": "Record not found"}
