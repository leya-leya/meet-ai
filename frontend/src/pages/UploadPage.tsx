import { type ChangeEvent, type FormEvent, useState } from "react";
import { useNavigate } from "react-router-dom";

import { processRecord, uploadRecord } from "../api/records";

export default function UploadPage() {
  const navigate = useNavigate();
  const [selectedFile, setSelectedFile] = useState<File | null>(null);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [processingStatus, setProcessingStatus] = useState("等待选择文件");
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  function handleFileChange(event: ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0] ?? null;
    setSelectedFile(file);
    setErrorMessage(null);
    setProcessingStatus(file ? "等待上传" : "等待选择文件");
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!selectedFile || isSubmitting) {
      return;
    }

    setErrorMessage(null);
    setIsSubmitting(true);
    setProcessingStatus("正在上传");
    try {
      const uploadedRecord = await uploadRecord(selectedFile);
      setProcessingStatus("正在转写并生成摘要");
      const completedRecord = await processRecord(uploadedRecord.id);
      if (completedRecord.status !== "completed") {
        throw new Error(completedRecord.error_message ?? "处理未完成");
      }
      setProcessingStatus("已完成");
      navigate(`/records/${completedRecord.id}`);
    } catch (error) {
      setProcessingStatus("处理失败");
      setErrorMessage(error instanceof Error ? error.message : "处理失败");
    } finally {
      setIsSubmitting(false);
    }
  }

  return (
    <section className="page-card">
      <p className="eyebrow">新建记录</p>
      <h1>上传音视频</h1>
      <p className="page-description">
        上传会议音频或视频，系统将生成完整转写与 AI 摘要。
      </p>
      <form className="upload-form" onSubmit={handleSubmit}>
        <div className="upload-guidance">
          <p>
            支持格式：<strong>MP3、WAV、M4A、MP4、MOV</strong>
          </p>
          <p>单个文件最大 500 MB</p>
        </div>

        <label className="file-picker">
          <span>选择音视频文件</span>
          <input
            accept=".mp3,.wav,.m4a,.mp4,.mov"
            disabled={isSubmitting}
            onChange={handleFileChange}
            type="file"
          />
        </label>

        <p className="selected-file">
          {selectedFile ? `已选择：${selectedFile.name}` : "尚未选择文件"}
        </p>
        <p aria-live="polite" className="processing-status">
          当前状态：{processingStatus}
        </p>
        {errorMessage ? (
          <p className="error-message" role="alert">
            {errorMessage}
          </p>
        ) : null}

        <button
          className="primary-button"
          disabled={!selectedFile || isSubmitting}
          type="submit"
        >
          {isSubmitting ? "处理中…" : "上传并处理"}
        </button>
      </form>
    </section>
  );
}
