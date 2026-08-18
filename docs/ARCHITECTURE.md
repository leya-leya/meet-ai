# AI 智能会议纪要与内容管理系统 V1.0 — 架构说明

## 1. 架构原则

V1.0 采用最简单的前后端分离结构：

```text
Browser
   │
   ▼
React + Vite
   │ HTTP JSON
   ▼
FastAPI
   ├── SQLite
   ├── Local uploads/
   ├── ASR Adapter → ASR Provider
   └── LLM Adapter → LLM Provider
```

不使用微服务。

不引入 Redis、消息队列、对象存储或容器编排。

---

## 2. 推荐目录

```text
frontend/
└─ src/
   ├─ api/
   │  └─ records.ts
   ├─ pages/
   │  ├─ UploadPage.tsx
   │  ├─ HistoryPage.tsx
   │  └─ RecordDetailPage.tsx
   ├─ components/
   │  ├─ AppLayout.tsx
   │  ├─ StatusBadge.tsx
   │  └─ ErrorMessage.tsx
   ├─ types/
   │  └─ record.ts
   ├─ App.tsx
   └─ main.tsx

backend/
├─ app/
│  ├─ main.py
│  ├─ db.py
│  ├─ api/
│  │  └─ records.py
│  ├─ models/
│  │  └─ record.py
│  ├─ schemas/
│  │  └─ record.py
│  ├─ services/
│  │  ├─ record_service.py
│  │  ├─ processing_service.py
│  │  └─ export_service.py
│  └─ providers/
│     ├─ asr/
│     │  ├─ base.py
│     │  └─ mock.py
│     └─ llm/
│        ├─ base.py
│        └─ mock.py
├─ tests/
│  ├─ test_records_api.py
│  ├─ test_processing_service.py
│  └─ test_export_service.py
└─ requirements.txt
```

文件应保持职责单一。

---

## 3. 数据模型

V1.0 只需要一个核心表：

```text
records
```

建议字段：

| 字段 | 类型 | 说明 |
|---|---|---|
| id | UUID/String | 主键 |
| title | String | 可编辑标题 |
| original_filename | String | 原文件名 |
| stored_filename | String | 本地实际文件名 |
| file_type | String | 扩展名 |
| file_size | Integer | 字节数 |
| status | String | 处理状态 |
| transcript | Text/Nullable | 完整转写 |
| summary | Text/Nullable | AI 摘要 |
| error_message | Text/Nullable | 失败信息 |
| created_at | DateTime | 创建时间 |
| updated_at | DateTime | 更新时间 |

V1.0 不创建：

- users
- organizations
- permissions
- tags
- folders
- jobs

---

## 4. 状态转换

```text
uploaded
  ↓
transcribing
  ↓
transcribed
  ↓
summarizing
  ↓
completed
```

任何处理阶段异常：

```text
failed
```

状态只能使用上述固定值。

---

## 5. 后端接口

API 前缀：

```text
/api
```

### 5.1 上传并创建记录

```http
POST /api/records
Content-Type: multipart/form-data
```

字段：

```text
file
```

返回：

```json
{
  "id": "uuid",
  "title": "example",
  "original_filename": "example.mp3",
  "file_type": ".mp3",
  "file_size": 123456,
  "status": "uploaded",
  "transcript": null,
  "summary": null,
  "error_message": null,
  "created_at": "2026-08-14T13:00:00",
  "updated_at": "2026-08-14T13:00:00"
}
```

---

### 5.2 启动处理

```http
POST /api/records/{id}/process
```

V1.0 可以同步完成：

```text
ASR → 保存 transcript → LLM → 保存 summary
```

不引入任务队列。

返回处理后的完整记录。

如果处理较慢，前端允许一直显示“处理中”。

---

### 5.3 历史记录

```http
GET /api/records
```

可选查询：

```text
?q=关键词
```

搜索字段：

```text
title
```

默认按 `created_at DESC`。

---

### 5.4 记录详情

```http
GET /api/records/{id}
```

返回完整记录。

---

### 5.5 编辑记录

```http
PATCH /api/records/{id}
Content-Type: application/json
```

请求体：

```json
{
  "title": "新标题",
  "summary": "修改后的摘要",
  "transcript": "修改后的转写"
}
```

字段可以只传其中一部分。

标题不能被更新为空字符串。

---

### 5.6 删除记录

```http
DELETE /api/records/{id}
```

成功：

```http
204 No Content
```

同时尝试删除本地上传文件。

---

### 5.7 TXT 导出

```http
GET /api/records/{id}/export/txt
```

响应：

```text
text/plain
```

---

### 5.8 Markdown 导出

```http
GET /api/records/{id}/export/md
```

响应：

```text
text/markdown
```

---

## 6. 前端数据类型

统一使用：

```ts
export type RecordStatus =
  | "uploaded"
  | "transcribing"
  | "transcribed"
  | "summarizing"
  | "completed"
  | "failed";

export interface RecordItem {
  id: string;
  title: string;
  original_filename: string;
  file_type: string;
  file_size: number;
  status: RecordStatus;
  transcript: string | null;
  summary: string | null;
  error_message: string | null;
  created_at: string;
  updated_at: string;
}
```

前后端字段保持一致，不做无意义字段映射。

---

## 7. 服务边界

### record_service

负责：

- 创建记录
- 查询记录
- 搜索
- 更新
- 删除

不得负责 AI 请求。

### processing_service

负责：

```text
读取文件
→ 调用 ASR Provider
→ 保存 transcript
→ 调用 LLM Provider
→ 保存 summary
→ 更新 status
```

### export_service

负责：

- 生成 TXT 字符串
- 生成 Markdown 字符串
- 生成安全下载文件名

### ASR Provider

统一接口语义：

```python
transcribe(file_path: str) -> str
```

### LLM Provider

统一接口语义：

```python
summarize(transcript: str) -> str
```

---

## 8. Provider 设计

业务层只依赖抽象接口。

例如：

```text
ProcessingService
   ↓
ASRProvider
   ├─ MockASRProvider
   └─ RealASRProvider（科大讯飞录音文件转写标准版）

ProcessingService
   ↓
LLMProvider
   ├─ MockLLMProvider
   └─ RealLLMProvider
```

开发和自动测试默认使用 Mock Provider。

真实 ASR Provider 已按 `docs/AI_INTEGRATION.md` 接入；真实 LLM Provider 在 Task 12 接入。

---

## 9. 文件系统

推荐：

```text
uploads/
data/
  app.db
```

程序启动时如果目录不存在则自动创建。

不得把用户上传文件存进 Git。

`.gitignore` 至少忽略：

```text
.env
uploads/*
data/*.db
backend/.venv/
frontend/node_modules/
```

允许通过 `.gitkeep` 保留空目录。

---

## 10. 同步处理策略

V1.0 明确允许：

```text
POST /records/{id}/process
```

在一个请求内顺序完成：

1. 转写
2. 摘要
3. 返回结果

原因：

- 内部工具
- 单用户
- 第一版
- 避免消息队列与异步任务系统

如果未来真实文件过长导致 HTTP 超时，再作为 V1.1 重新设计。

V1.0 不提前解决这个问题。

---

## 11. 错误响应

后端统一使用清晰的 HTTP 状态码与 `detail`：

示例：

```json
{
  "detail": "Unsupported file type: .exe"
}
```

建议：

- 400：请求内容错误
- 404：记录不存在
- 413：文件过大
- 500：内部处理失败
- 502：外部 AI 服务失败

前端展示 `detail`，不要只显示“Unknown Error”。

---

## 12. 软著友好原则

保持：

- 清晰的自主业务结构
- 自己的页面和业务代码
- 自己的 Provider 抽象
- 自己的数据结构
- 自己的产品文档
- 连续版本记录

不要把整个系统写成一个脚本文件。
不要简单拼接第三方演示代码作为主体。
