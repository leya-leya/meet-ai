import re

from app.models.record import Record


_INVALID_FILENAME_CHARACTERS = re.compile(r'[<>:"/\\|?*\x00-\x1f]')


def _created_at_text(record: Record) -> str:
    return record.created_at.isoformat(sep=" ", timespec="seconds")


def generate_txt(record: Record) -> str:
    summary = record.summary or ""
    transcript = record.transcript or ""
    return (
        f"{record.title}\n"
        f"创建时间：{_created_at_text(record)}\n"
        f"原始文件名：{record.original_filename}\n\n"
        "AI 摘要\n"
        "====================\n\n"
        f"{summary}\n\n"
        "完整转写\n"
        "====================\n\n"
        f"{transcript}\n"
    )


def generate_markdown(record: Record) -> str:
    summary = record.summary or ""
    transcript = record.transcript or ""
    return (
        f"# {record.title}\n\n"
        f"- 创建时间：{_created_at_text(record)}\n"
        f"- 原始文件名：{record.original_filename}\n\n"
        "## AI 摘要\n\n"
        f"{summary}\n\n"
        "## 完整转写\n\n"
        f"{transcript}\n"
    )


def build_download_filename(title: str, extension: str) -> str:
    safe_title = _INVALID_FILENAME_CHARACTERS.sub("_", title).strip().rstrip(".")
    if not safe_title:
        safe_title = "record"
    return f"{safe_title}.{extension.lstrip('.')}"
