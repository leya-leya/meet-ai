# AI 智能会议纪要与内容管理系统 V1.0

一个供公司内部使用的轻量级音视频内容整理工具。

V1.0 只解决一个完整流程：

> 上传音视频 → 转文字 → AI 摘要 → 内容编辑 → 历史记录 → 导出

项目同时按照后续软件著作权材料整理的需求，保留清晰的代码结构、版本记录、功能说明和页面截图。

---

## 1. V1.0 功能

- 上传 MP3 / WAV / M4A / MP4 / MOV
- 保存上传记录
- 调用 ASR 转写音视频
- 调用大模型生成摘要
- 编辑并保存摘要
- 编辑并保存完整转写
- 查看历史记录
- 按标题搜索
- 删除记录
- TXT 导出
- Markdown 导出

详细定义见：

`docs/PRODUCT_SPEC.md`

---

## 2. 技术栈

### Frontend

- React
- Vite
- TypeScript

### Backend

- Python
- FastAPI
- SQLAlchemy
- SQLite

### Storage

- 本地 `uploads/`

### AI

- ASR Provider Adapter
- LLM Provider Adapter

---

## 3. 推荐目录结构

```text
ai-meeting-assistant/
├─ AGENTS.md
├─ README.md
├─ .env.example
├─ .gitignore
├─ frontend/
│  ├─ src/
│  └─ package.json
├─ backend/
│  ├─ app/
│  │  ├─ main.py
│  │  ├─ api/
│  │  ├─ models/
│  │  ├─ schemas/
│  │  ├─ services/
│  │  └─ providers/
│  ├─ tests/
│  └─ requirements.txt
├─ uploads/
├─ data/
└─ docs/
   ├─ PRODUCT_SPEC.md
   ├─ ARCHITECTURE.md
   ├─ DEVELOPMENT_PLAN.md
   ├─ TESTING.md
   ├─ AI_INTEGRATION.md
   ├─ SOFT_COPYRIGHT.md
   └─ screenshots/
```

---

## 4. 本地运行目标

最终 V1.0 应能通过两个本地进程启动：

### Backend

```bash
cd backend
python -m venv .venv
```

Windows PowerShell：

```powershell
.venv\Scripts\Activate.ps1
```

安装依赖：

```bash
pip install -r requirements.txt
```

启动：

```bash
uvicorn app.main:app --reload --port 8000
```

### Frontend

```bash
cd frontend
npm install
npm run dev
```

前端默认访问：

```text
http://localhost:5173
```

后端默认访问：

```text
http://localhost:8000
```

---

## 5. 环境变量

项目根目录或后端目录应提供 `.env.example`，内容只放变量名和示例占位值：

```env
ASR_PROVIDER=mock
ASR_APP_ID=
ASR_SECRET_KEY=
LLM_PROVIDER=mock
LLM_API_KEY=
DATABASE_URL=sqlite:///./data/app.db
UPLOAD_DIR=./uploads
MAX_UPLOAD_MB=500
```

真实 `.env` 不得提交到 Git。

ASR 自动测试和本地无外网开发默认使用 `mock`。使用科大讯飞录音文件转写标准版时，在项目根目录 `.env` 中设置：

```env
ASR_PROVIDER=xfyun
ASR_APP_ID=
ASR_SECRET_KEY=
```

`ASR_APP_ID` 和 `ASR_SECRET_KEY` 只由后端读取，不得写入前端、源码或日志。

---

## 6. 开发方式

每次让 Codex 工作时，优先使用这种指令：

```text
请先阅读 AGENTS.md、
docs/PRODUCT_SPEC.md、
docs/ARCHITECTURE.md、
docs/DEVELOPMENT_PLAN.md。

只执行 DEVELOPMENT_PLAN.md 中下一项尚未完成的任务。

不要开发任何范围外功能。
完成后运行相关测试，并按照 AGENTS.md 指定格式汇报。
```

如果指定某项任务：

```text
请先读取项目文档。
只执行 docs/DEVELOPMENT_PLAN.md 的 Task 3。
不要提前执行 Task 4，也不要顺手新增功能。
完成后运行相关测试并汇报。
```

---

## 7. V1.0 验收流程

最终必须能够实际完成：

1. 打开上传页。
2. 上传一个支持格式的音频或视频。
3. 系统建立记录。
4. 完成转写。
5. 完成 AI 摘要。
6. 打开详情页。
7. 修改摘要。
8. 修改转写文本。
9. 保存。
10. 回到历史记录。
11. 搜索并重新打开该记录。
12. 导出 TXT。
13. 导出 Markdown。
14. 删除记录。
15. 确认数据库记录与本地文件均被删除。

---

## 8. 版本记录

不单独创建 `CHANGELOG.md`，V1.0 阶段直接维护本节，避免文档数量继续膨胀。

格式统一为：

```text
YYYY-MM-DD | 版本/阶段 | 简要变更 | 对应任务
```

开发时在下方追加，不修改历史记录。

### 记录

```text
2026-08-14 | 0.0.1 | 建立 V1.0 项目约束与开发文档 | 项目初始化
2026-08-14 | 0.1.0 | 完成后端基础骨架、健康检查与 SQLite records 表 | Task 1
2026-08-14 | 0.2.0 | 完成音视频上传、文件校验与 uploaded 记录创建 | Task 2
2026-08-14 | 0.3.0 | 完成 ASR/LLM Provider 抽象、Mock 与处理状态流转 | Task 3
2026-08-14 | 0.4.0 | 完成同步处理 API 与本地文件缺失错误处理 | Task 4
2026-08-14 | 0.5.0 | 完成历史记录、标题搜索、详情编辑与删除 API | Task 5
2026-08-15 | 0.6.0 | 完成 TXT 与 Markdown 导出 API | Task 6
2026-08-15 | 0.7.0 | 完成 React 前端骨架、三页面路由与 records API 模块 | Task 7
2026-08-17 | 0.8.0 | 完成单文件上传、同步处理状态与详情跳转 | Task 8
2026-08-17 | 0.9.0 | 完成历史记录列表、标题搜索与单条删除交互 | Task 9
2026-08-17 | 0.10.0 | 完成详情编辑保存、TXT/Markdown 下载与详情删除交互 | Task 10
2026-08-18 | 0.11.0 | 接入科大讯飞录音文件转写标准版并完成真实媒体验证 | Task 11
```

---

## 9. V1.0 不做什么

完整禁止项见 `AGENTS.md`。

最重要的原则是：

> 没有写入 PRODUCT_SPEC.md 的产品功能，默认不开发。

V1.0 完成后再讨论 V1.1。
