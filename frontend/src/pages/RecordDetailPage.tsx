import { type FormEvent, useEffect, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";

import {
  deleteRecord,
  downloadRecord,
  getRecord,
  updateRecord,
} from "../api/records";
import type { RecordItem, RecordStatus } from "../types/record";

const STATUS_LABELS: Record<RecordStatus, string> = {
  uploaded: "已上传",
  transcribing: "正在转写",
  transcribed: "已转写",
  summarizing: "正在生成摘要",
  completed: "已完成",
  failed: "处理失败",
};

type DetailAction = "save" | "delete" | "txt" | "md" | null;

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

export default function RecordDetailPage() {
  const navigate = useNavigate();
  const { id } = useParams<{ id: string }>();
  const [record, setRecord] = useState<RecordItem | null>(null);
  const [title, setTitle] = useState("");
  const [summary, setSummary] = useState("");
  const [transcript, setTranscript] = useState("");
  const [isLoading, setIsLoading] = useState(true);
  const [activeAction, setActiveAction] = useState<DetailAction>(null);
  const [errorMessage, setErrorMessage] = useState("");
  const [successMessage, setSuccessMessage] = useState("");

  useEffect(() => {
    let isCurrent = true;

    async function loadRecord() {
      if (!id) {
        setErrorMessage("记录不存在");
        setIsLoading(false);
        return;
      }
      try {
        const loadedRecord = await getRecord(id);
        if (!isCurrent) {
          return;
        }
        setRecord(loadedRecord);
        setTitle(loadedRecord.title);
        setSummary(loadedRecord.summary ?? "");
        setTranscript(loadedRecord.transcript ?? "");
      } catch (error) {
        if (isCurrent) {
          setErrorMessage(error instanceof Error ? error.message : "记录读取失败");
        }
      } finally {
        if (isCurrent) {
          setIsLoading(false);
        }
      }
    }

    void loadRecord();
    return () => {
      isCurrent = false;
    };
  }, [id]);

  async function handleSave(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!id || !record || activeAction) {
      return;
    }
    const trimmedTitle = title.trim();
    if (!trimmedTitle) {
      setSuccessMessage("");
      setErrorMessage("标题不能为空");
      return;
    }

    setActiveAction("save");
    setErrorMessage("");
    setSuccessMessage("");
    try {
      const savedRecord = await updateRecord(id, {
        title: trimmedTitle,
        summary,
        transcript,
      });
      setRecord(savedRecord);
      setTitle(savedRecord.title);
      setSummary(savedRecord.summary ?? "");
      setTranscript(savedRecord.transcript ?? "");
      setSuccessMessage("保存成功");
    } catch (error) {
      setErrorMessage(error instanceof Error ? error.message : "保存编辑失败");
    } finally {
      setActiveAction(null);
    }
  }

  async function handleDownload(format: "txt" | "md") {
    if (!id || activeAction) {
      return;
    }
    setActiveAction(format);
    setErrorMessage("");
    setSuccessMessage("");
    try {
      const { blob, filename } = await downloadRecord(id, format);
      const downloadUrl = URL.createObjectURL(blob);
      const anchor = document.createElement("a");
      anchor.href = downloadUrl;
      anchor.download = filename;
      document.body.append(anchor);
      anchor.click();
      anchor.remove();
      URL.revokeObjectURL(downloadUrl);
    } catch (error) {
      setErrorMessage(error instanceof Error ? error.message : "导出失败");
    } finally {
      setActiveAction(null);
    }
  }

  async function handleDelete() {
    if (!id || !record || activeAction) {
      return;
    }
    if (!window.confirm(`确认删除“${record.title}”？`)) {
      return;
    }

    setActiveAction("delete");
    setErrorMessage("");
    setSuccessMessage("");
    try {
      await deleteRecord(id);
      navigate("/history");
    } catch (error) {
      setErrorMessage(error instanceof Error ? error.message : "删除记录失败");
      setActiveAction(null);
    }
  }

  return (
    <section className="page-card detail-page">
      <p className="eyebrow">会议内容</p>
      <h1>记录详情</h1>
      <p className="page-description">编辑、导出或删除这条会议内容记录。</p>

      {isLoading ? <p className="detail-message">正在读取记录…</p> : null}

      {!isLoading && !record && errorMessage ? (
        <p className="error-message detail-message" role="alert">
          {errorMessage}
        </p>
      ) : null}

      {record ? (
        <>
          <dl className="detail-meta">
            <div>
              <dt>原始文件名</dt>
              <dd>{record.original_filename}</dd>
            </div>
            <div>
              <dt>创建时间</dt>
              <dd>
                <time dateTime={record.created_at}>
                  {formatCreatedAt(record.created_at)}
                </time>
              </dd>
            </div>
            <div>
              <dt>状态</dt>
              <dd>
                <span className={`record-status status-${record.status}`}>
                  {STATUS_LABELS[record.status]}
                </span>
              </dd>
            </div>
          </dl>

          {record.status === "failed" && record.error_message ? (
            <p className="error-message detail-message" role="alert">
              {record.error_message}
            </p>
          ) : null}

          <form className="detail-form" onSubmit={handleSave}>
            <label htmlFor="record-title">标题</label>
            <input
              id="record-title"
              onChange={(event) => setTitle(event.target.value)}
              type="text"
              value={title}
            />

            <label htmlFor="record-summary">AI 摘要</label>
            <textarea
              id="record-summary"
              onChange={(event) => setSummary(event.target.value)}
              rows={10}
              value={summary}
            />

            <label htmlFor="record-transcript">完整转写</label>
            <textarea
              id="record-transcript"
              onChange={(event) => setTranscript(event.target.value)}
              rows={16}
              value={transcript}
            />

            {errorMessage ? (
              <p className="error-message" role="alert">
                {errorMessage}
              </p>
            ) : null}
            {successMessage ? (
              <p className="success-message" role="status">
                {successMessage}
              </p>
            ) : null}

            <div className="detail-actions">
              <button
                className="primary-button"
                disabled={activeAction !== null}
                type="submit"
              >
                {activeAction === "save" ? "正在保存…" : "保存修改"}
              </button>
              <button
                className="secondary-button"
                disabled={activeAction !== null}
                onClick={() => void handleDownload("txt")}
                type="button"
              >
                {activeAction === "txt" ? "正在导出…" : "下载 TXT"}
              </button>
              <button
                className="secondary-button"
                disabled={activeAction !== null}
                onClick={() => void handleDownload("md")}
                type="button"
              >
                {activeAction === "md" ? "正在导出…" : "下载 Markdown"}
              </button>
              <button
                className="danger-button"
                disabled={activeAction !== null}
                onClick={() => void handleDelete()}
                type="button"
              >
                {activeAction === "delete" ? "正在删除…" : "删除记录"}
              </button>
            </div>
          </form>
        </>
      ) : null}
    </section>
  );
}
