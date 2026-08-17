import { FormEvent, useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";

import { deleteRecord, listRecords } from "../api/records";
import type { RecordItem, RecordStatus } from "../types/record";

const STATUS_LABELS: Record<RecordStatus, string> = {
  uploaded: "已上传",
  transcribing: "正在转写",
  transcribed: "已转写",
  summarizing: "正在生成摘要",
  completed: "已完成",
  failed: "处理失败",
};

function formatCreatedAt(value: string) {
  return new Intl.DateTimeFormat("zh-CN", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).format(new Date(value));
}

export default function HistoryPage() {
  const [records, setRecords] = useState<RecordItem[]>([]);
  const [query, setQuery] = useState("");
  const [isLoading, setIsLoading] = useState(true);
  const [deletingId, setDeletingId] = useState<string | null>(null);
  const [errorMessage, setErrorMessage] = useState("");
  const activeQueryRef = useRef("");
  const listRequestIdRef = useRef(0);

  async function loadRecords(searchQuery: string) {
    const requestId = ++listRequestIdRef.current;
    setIsLoading(true);
    setErrorMessage("");
    try {
      const nextRecords = await listRecords(searchQuery || undefined);
      if (requestId === listRequestIdRef.current) {
        setRecords(nextRecords);
      }
    } catch (error) {
      if (requestId === listRequestIdRef.current) {
        setErrorMessage(
          error instanceof Error ? error.message : "历史记录读取失败",
        );
      }
    } finally {
      if (requestId === listRequestIdRef.current) {
        setIsLoading(false);
      }
    }
  }

  useEffect(() => {
    void loadRecords("");
  }, []);

  function handleSearch(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const nextQuery = query.trim();
    activeQueryRef.current = nextQuery;
    void loadRecords(nextQuery);
  }

  async function handleDelete(record: RecordItem) {
    if (!window.confirm(`确认删除“${record.title}”？`)) {
      return;
    }

    setDeletingId(record.id);
    setErrorMessage("");
    try {
      await deleteRecord(record.id);
      await loadRecords(activeQueryRef.current);
    } catch (error) {
      setErrorMessage(error instanceof Error ? error.message : "删除记录失败");
    } finally {
      setDeletingId(null);
    }
  }

  return (
    <section className="page-card history-page">
      <p className="eyebrow">内容管理</p>
      <h1>历史记录</h1>
      <p className="page-description">查看和搜索已经创建的会议内容记录。</p>

      <form className="history-search" onSubmit={handleSearch}>
        <label htmlFor="record-search">搜索标题</label>
        <div className="history-search-controls">
          <input
            id="record-search"
            onChange={(event) => setQuery(event.target.value)}
            placeholder="输入记录标题"
            type="search"
            value={query}
          />
          <button className="primary-button" disabled={isLoading} type="submit">
            搜索
          </button>
        </div>
      </form>

      {errorMessage ? (
        <p className="error-message history-message" role="alert">
          {errorMessage}
        </p>
      ) : null}

      {isLoading ? <p className="history-message">正在读取历史记录…</p> : null}

      {!isLoading && records.length === 0 ? (
        <p className="history-empty">暂无历史记录</p>
      ) : null}

      {!isLoading && records.length > 0 ? (
        <div className="record-list">
          {records.map((record) => (
            <article className="record-card" key={record.id}>
              <div className="record-card-heading">
                <Link className="record-title" to={`/records/${record.id}`}>
                  {record.title}
                </Link>
                <span className={`record-status status-${record.status}`}>
                  {STATUS_LABELS[record.status]}
                </span>
              </div>
              <dl className="record-meta">
                <div>
                  <dt>原始文件名</dt>
                  <dd>{record.original_filename}</dd>
                </div>
                <div>
                  <dt>类型</dt>
                  <dd>{record.file_type}</dd>
                </div>
                <div>
                  <dt>创建时间</dt>
                  <dd>
                    <time dateTime={record.created_at}>
                      {formatCreatedAt(record.created_at)}
                    </time>
                  </dd>
                </div>
              </dl>
              <button
                className="delete-button"
                disabled={deletingId === record.id}
                onClick={() => void handleDelete(record)}
                type="button"
              >
                {deletingId === record.id ? "正在删除…" : "删除"}
              </button>
            </article>
          ))}
        </div>
      ) : null}
    </section>
  );
}
