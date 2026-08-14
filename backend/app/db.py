import os
from collections.abc import Iterator
from pathlib import Path

from sqlalchemy import create_engine
from sqlalchemy.engine import Engine
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker


PROJECT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_DATABASE_PATH = PROJECT_ROOT / "data" / "app.db"


def resolve_storage_path(configured_path: str) -> Path:
    path = Path(configured_path)
    if path.is_absolute():
        return path
    return (PROJECT_ROOT / path).resolve()


def resolve_database_url(configured_url: str) -> str:
    prefix = "sqlite:///"
    if not configured_url.startswith(prefix) or configured_url == "sqlite:///:memory:":
        return configured_url
    database_path = resolve_storage_path(configured_url.removeprefix(prefix))
    return f"{prefix}{database_path.as_posix()}"


DATABASE_URL = resolve_database_url(
    os.getenv(
        "DATABASE_URL",
        f"sqlite:///{DEFAULT_DATABASE_PATH.as_posix()}",
    )
)
UPLOAD_DIR = resolve_storage_path(
    os.getenv("UPLOAD_DIR", str(PROJECT_ROOT / "uploads"))
)


class Base(DeclarativeBase):
    pass


def _database_file_path(database_url: str) -> Path | None:
    prefix = "sqlite:///"
    if not database_url.startswith(prefix) or database_url == "sqlite:///:memory:":
        return None
    return Path(database_url.removeprefix(prefix))


def _create_engine(database_url: str) -> Engine:
    connect_args = (
        {"check_same_thread": False}
        if database_url.startswith("sqlite:")
        else {}
    )
    return create_engine(database_url, connect_args=connect_args)


engine = _create_engine(DATABASE_URL)
SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False)


def get_db() -> Iterator[Session]:
    with SessionLocal() as session:
        yield session


def init_db() -> None:
    from app.models.record import Record

    _ = Record
    database_path = _database_file_path(DATABASE_URL)
    if database_path is not None:
        database_path.parent.mkdir(parents=True, exist_ok=True)
    UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
    Base.metadata.create_all(bind=engine)
