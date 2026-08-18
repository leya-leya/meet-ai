# AI 智能会议纪要与内容管理系统 V1.0 — Implementation Plan

> **For agentic workers:** 每次只执行一个 Task。每个 Task 完成后必须运行验证，再更新复选框。不得提前实现后续 Task。

**Goal:** 完成“上传音视频 → 转文字 → AI摘要 → 内容编辑 → 历史记录 → 导出”的内部 MVP。

**Architecture:** React/Vite/TypeScript 前端通过 HTTP 调用 FastAPI；FastAPI 使用 SQLite 保存记录、本地目录保存上传文件；ASR 与 LLM 通过 Provider 接口接入。V1.0 同步处理，不使用任务队列。

**Tech Stack:** React, Vite, TypeScript, Python, FastAPI, SQLAlchemy, SQLite, pytest.

## Global Constraints

- 只有三个主页面：上传页、历史记录页、记录详情页。
- 只实现 `PRODUCT_SPEC.md` 定义的 V1.0。
- 不引入用户系统、微服务、Redis、消息队列、Docker、RAG。
- AI Provider 必须可替换。
- 默认使用 Mock Provider 完成测试。
- 修改后必须运行相关测试。
- 每项任务完成后在 README 版本记录追加一行。

---

## Task 1：后端基础骨架与数据库

**目标：** 后端能够启动，并创建 SQLite `records` 表。

**创建/修改：**

```text
backend/app/main.py
backend/app/db.py
backend/app/models/record.py
backend/app/schemas/record.py
backend/requirements.txt
backend/tests/test_health.py
backend/tests/test_database.py
.env.example
.gitignore
```

**必须实现：**

- FastAPI 应用可启动。
- `GET /health` 返回：

```json
{"status":"ok"}
```

- 创建 `records` 数据模型。
- 启动或测试时可以创建表。
- 自动创建 `data/` 和 `uploads/` 所需目录。

**验证命令：**

```bash
cd backend
pytest tests/test_health.py tests/test_database.py -v
```

**验收：**

- [x] `/health` 测试通过
- [x] SQLite 表创建测试通过
- [x] `.env` 被 gitignore
- [x] `uploads/` 内容被 gitignore
- [x] `data/*.db` 被 gitignore

---

## Task 2：上传与创建记录

**目标：** 用户能上传支持格式文件并创建一条 `uploaded` 记录。

**主要文件：**

```text
backend/app/api/records.py
backend/app/services/record_service.py
backend/tests/test_records_api.py
```

**接口：**

```http
POST /api/records
```

**必须行为：**

- 校验扩展名。
- 校验最大 500 MB。
- 使用 UUID 生成内部文件名。
- 文件保存到 `uploads/`。
- 默认标题为去掉扩展名的原始文件名。
- 创建数据库记录。
- `status = uploaded`。

**测试至少覆盖：**

- [x] MP3 上传成功
- [x] MP4 上传成功
- [x] 不支持扩展名返回 400
- [x] 同名文件不会覆盖
- [x] 原始文件名被保留
- [x] 默认标题正确

**验证：**

```bash
pytest tests/test_records_api.py -v
```

---

## Task 3：ASR 与 LLM Provider 接口

**目标：** 建立与厂商无关的 AI 适配层，并用 Mock 完成处理流程测试。

**创建：**

```text
backend/app/providers/asr/base.py
backend/app/providers/asr/mock.py
backend/app/providers/llm/base.py
backend/app/providers/llm/mock.py
backend/app/services/processing_service.py
backend/tests/test_processing_service.py
```

**固定接口语义：**

```python
transcribe(file_path: str) -> str
```

```python
summarize(transcript: str) -> str
```

**MockASRProvider：**

输入任意存在的测试文件，返回固定测试转写：

```text
这是一段用于自动化测试的转写文本。
```

**MockLLMProvider：**

返回包含以下标题的 Markdown：

```text
## 内容摘要
## 核心要点
## 待办事项
```

**处理状态必须依次更新：**

```text
uploaded
→ transcribing
→ transcribed
→ summarizing
→ completed
```

发生异常：

```text
failed
```

并写入 `error_message`。

**测试：**

- [x] 正常流程最终 `completed`
- [x] transcript 被保存
- [x] summary 被保存
- [x] ASR 异常最终 `failed`
- [x] LLM 异常最终 `failed`
- [x] 错误信息被保存

---

## Task 4：处理 API

**目标：** 可以通过 API 对指定记录执行完整处理。

**接口：**

```http
POST /api/records/{id}/process
```

**必须行为：**

- 找不到记录返回 404。
- 找不到对应本地文件返回明确错误。
- 正常时调用 `processing_service`。
- 返回处理后的完整记录。

**测试：**

- [x] 上传后调用 process 可得到 `completed`
- [x] 返回 transcript
- [x] 返回 summary
- [x] 不存在 ID 返回 404

**验收命令：**

```bash
pytest tests/test_records_api.py tests/test_processing_service.py -v
```

---

## Task 5：历史记录、详情、编辑、删除 API

**目标：** 后端 CRUD 闭环。

**接口：**

```http
GET /api/records
GET /api/records?q=关键词
GET /api/records/{id}
PATCH /api/records/{id}
DELETE /api/records/{id}
```

**必须行为：**

历史记录：

- 创建时间倒序。
- `q` 只对 `title` 做部分匹配。

编辑：

允许修改：

```text
title
summary
transcript
```

标题不可为空。

删除：

- 删除数据库记录。
- 文件存在则删除本地文件。
- 文件不存在也允许成功删除数据库记录。

**测试：**

- [x] 列表倒序
- [x] 标题搜索
- [x] 详情查询
- [x] 修改标题
- [x] 修改摘要
- [x] 修改 transcript
- [x] 空标题拒绝
- [x] 删除记录
- [x] 删除本地文件
- [x] 本地文件缺失时仍可删除记录

---

## Task 6：TXT 与 Markdown 导出

**目标：** 后端按产品规格生成两种导出。

**创建：**

```text
backend/app/services/export_service.py
backend/tests/test_export_service.py
```

**接口：**

```http
GET /api/records/{id}/export/txt
GET /api/records/{id}/export/md
```

**必须覆盖：**

- 标题
- 创建时间
- 原始文件名
- AI 摘要
- 完整转写

**测试：**

- [x] TXT Content-Type 正确
- [x] Markdown Content-Type 正确
- [x] 下载文件名合理
- [x] 内容包含摘要
- [x] 内容包含 transcript
- [x] 不存在记录返回 404

---

## Task 7：前端基础与路由

**目标：** React 应用启动，有三个主页面路由。

**创建：**

```text
frontend/src/main.tsx
frontend/src/App.tsx
frontend/src/pages/UploadPage.tsx
frontend/src/pages/HistoryPage.tsx
frontend/src/pages/RecordDetailPage.tsx
frontend/src/components/AppLayout.tsx
frontend/src/types/record.ts
frontend/src/api/records.ts
```

**路由：**

```text
/                 上传页
/history          历史记录
/records/:id      详情页
```

**要求：**

- 顶部只提供“上传”“历史记录”两个主导航。
- 不增加仪表盘。
- 不增加设置中心。
- 不增加登录页。

**验证：**

```bash
npm run build
```

- [x] Build 通过
- [x] 三个 URL 可正常显示页面骨架

---

## Task 8：上传页

**目标：** 从浏览器完成上传和处理，并进入详情页。

**页面行为：**

```text
选择文件
→ POST /api/records
→ POST /api/records/{id}/process
→ navigate /records/{id}
```

**必须显示：**

- 支持格式
- 最大 500 MB
- 已选择文件
- 当前状态
- 错误消息

**不得实现：**

- 拖拽复杂动画
- 上传进度百分比
- 批量上传

**测试/验证：**

- [x] 未选择文件时不能提交
- [x] API 错误可见
- [x] 成功后进入详情
- [x] `npm run build` 通过

---

## Task 9：历史记录页

**目标：** 查看和搜索历史记录。

**功能：**

- 获取 `/api/records`
- 显示标题、文件名、类型、时间、状态
- 标题搜索
- 点击进入详情
- 删除

**要求：**

- 默认倒序由后端保证。
- 搜索使用 `?q=`。
- 删除前使用简单浏览器确认即可。
- 不开发批量删除。

**验证：**

- [x] 列表可加载
- [x] 搜索可用
- [x] 点击可进详情
- [x] 删除后列表刷新
- [x] `npm run build` 通过

---

## Task 10：详情编辑与导出

**目标：** 完成整个 V1.0 用户闭环。

**页面字段：**

- 标题输入框
- AI 摘要 textarea
- 完整转写 textarea

**操作：**

- 保存
- TXT 导出
- Markdown 导出
- 删除

**要求：**

- 刷新页面后编辑结果仍存在。
- 保存成功显示简单成功提示。
- `failed` 状态显示 `error_message`。
- 如果已有 transcript/summary，即使 failed 也要展示。

**验收：**

- [x] 标题修改可保存
- [x] 摘要修改可保存
- [x] 转写修改可保存
- [x] TXT 能下载
- [x] Markdown 能下载
- [x] 删除可用
- [x] Build 通过

---

## Task 11：接入真实 ASR Provider

**目标：** 在不改变业务层接口的前提下，加入一个真实语音识别 Provider。

**必须遵守：**

- API Key 只来自环境变量。
- Provider 实现 `transcribe(file_path: str) -> str`。
- 不修改 `processing_service` 的业务语义。
- Mock Provider 继续保留用于测试。
- 第三方请求失败转换为明确异常。

**验证：**

- [x] Mock 自动测试仍全部通过
- [x] 使用一个 1–5 分钟真实音视频完成转写
- [x] 不提交真实 API Key
- [x] 在 `docs/SOFT_COPYRIGHT.md` 记录所用第三方服务只作为外部能力依赖

---

## Task 12：接入真实 LLM Provider

**目标：** 接入一个真实大模型摘要服务。

**固定输出要求：**

```markdown
## 内容摘要

...

## 核心要点

- ...

## 待办事项

- ...
```

**必须遵守：**

- 不允许模型自动修改 transcript。
- 不允许模型直接修改数据库。
- API Key 不得进入前端。
- Mock Provider 继续用于自动测试。

**验收：**

- [x] 真实 transcript 可以生成摘要
- [x] 三个固定标题存在
- [x] API 失败有错误提示
- [x] 自动测试仍通过

---

## Task 13：端到端验收与软著截图

**目标：** 用真实文件完成一次完整 V1.0 流程并形成证据。

**操作顺序：**

1. 上传一个真实 1–5 分钟音视频。
2. 等待转写完成。
3. 等待摘要完成。
4. 修改标题。
5. 修改摘要。
6. 修改 transcript。
7. 保存。
8. 在历史记录搜索标题。
9. 重新打开。
10. 导出 TXT。
11. 导出 Markdown。
12. 删除测试记录。

**截图至少保存：**

```text
docs/screenshots/01-upload.png
docs/screenshots/02-processing.png
docs/screenshots/03-detail.png
docs/screenshots/04-edit.png
docs/screenshots/05-history.png
docs/screenshots/06-search.png
docs/screenshots/07-export.png
```

**最终验证：**

后端：

```bash
cd backend
pytest -v
```

前端：

```bash
cd frontend
npm run build
```

全部通过后：

- [x] 更新 README 版本记录为 `1.0.0`
- [x] 更新 `docs/SOFT_COPYRIGHT.md` 的实际完成信息
- [x] 不再新增 V1.0 功能
- [x] 创建 Git tag `v1.0.0`
