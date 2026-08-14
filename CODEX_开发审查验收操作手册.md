# AI 智能会议纪要与内容管理系统 V1.0
# Codex 开发 / Reviewer / 人工验收操作手册

> 固定流程：**主开发 → Reviewer → 你人工验收 → PASS → 下一 Task**
>
> 每次只做一个 Task。主开发和 Reviewer 都不得自动继续下一 Task。

## 统一使用规则

### 主开发通用前缀

每次把下面前缀 + 对应 Task 的“主开发指令”一起复制给 Codex：

```text
你是本项目主开发。

开始前先阅读：
- AGENTS.md
- docs/PRODUCT_SPEC.md
- docs/ARCHITECTURE.md
- docs/DEVELOPMENT_PLAN.md
- docs/TESTING.md

涉及 AI 时再阅读：
- docs/AI_INTEGRATION.md

涉及软著/最终版本时再阅读：
- docs/SOFT_COPYRIGHT.md

严格遵守：
1. 只完成当前 Task。
2. 不提前实现后续 Task。
3. 不增加 PRODUCT_SPEC.md 之外的功能。
4. 先检查现有实现，做最小修改。
5. 完成后运行当前 Task 要求的测试及必要回归测试。
6. 检查 git status / git diff。
7. 更新 README 版本记录。
8. 当前 Task 独立 Git commit。
9. 不自动继续下一 Task。
10. 最后给出：完成内容、测试命令与结果、变更文件、commit SHA。
```

### Reviewer 通用前缀

每次开一个新的 Reviewer Codex 会话，复制：

```text
你是本项目独立代码 Reviewer，不是新功能开发者。

先阅读：
AGENTS.md
docs/PRODUCT_SPEC.md
docs/ARCHITECTURE.md
docs/DEVELOPMENT_PLAN.md
docs/TESTING.md

必要时再读 AI_INTEGRATION.md / SOFT_COPYRIGHT.md。

请审查最近一个“当前 Task”的 commit 和 git diff。

规则：
1. 不开发下一 Task。
2. Critical / Important 问题允许做最小修复并重新测试。
3. Minor 问题可以记录，不要为了洁癖大范围重构。
4. 检查测试是不是真测试。
5. 检查是否范围外开发。
6. 检查 README 是否更新。
7. 最后必须输出：

### 审查结论
PASS / PASS WITH FIXES / FAIL

### Critical
...

### Important
...

### Minor
...

### 已修复
...

### 测试结果
...

### Reviewer 修改文件
...

### 是否允许进入下一 Task
YES / NO
```

### 你自己的通用验收原则

你不需要逐行读代码。每次优先检查：

1. **实际行为能不能跑通**
2. **测试是不是 0 failed**
3. **Reviewer 是否 YES**
4. **git diff 是否只包含当前任务相关内容**
5. **关键文件有没有明显跑偏**

通用 Git 检查：

```bash
git status
git log --oneline -5
git show --stat HEAD
```

如果 Reviewer = FAIL / NO，或测试失败、Key 泄露、接口与文档明显不一致，都不要进入下一 Task。

---

# Task 1：后端基础骨架与数据库
## A. 主开发指令

```text
只执行 Task 1：后端基础骨架与数据库。
必须完成：FastAPI 基础应用、GET /health、SQLite 连接、records 数据模型、data/ 与 uploads/ 目录准备、Task 1 测试、.env/.db/uploads 的 gitignore。
records 字段必须与 ARCHITECTURE.md 一致：
id, title, original_filename, stored_filename, file_type, file_size, status, transcript, summary, error_message, created_at, updated_at。
禁止提前实现上传、ASR、LLM、导出、用户系统。
完成后运行：
cd backend
pytest tests/test_health.py tests/test_database.py -v
再运行完整后端测试（如已有）。
更新 README 版本记录，独立 commit，不开始 Task 2。
```
## B. Reviewer 指令

先发送上面的“Reviewer 通用前缀”，再追加：

```text
重点审查 /health、SQLite、records 字段、真实测试、gitignore、requirements 是否过度、是否提前实现 Task 2+。
必须检查 test_health/test_database 不是 assert True 一类假测试。
运行 Task 1 测试；Critical/Important 做最小修复；不得开发 Task 2。
最后明确：是否允许进入 Task 2：YES / NO
```
## C. 你重点看的文件

- `backend/app/main.py`
- `backend/app/db.py`
- `backend/app/models/record.py`
- `backend/app/schemas/record.py`
- `backend/tests/test_health.py`
- `backend/tests/test_database.py`
- `backend/requirements.txt`
- `.env.example`
- `.gitignore`
- `README.md`

## D. 你的人工验收

- [ ] /health 返回 {"status":"ok"}
- [ ] FastAPI 能启动
- [ ] records 字段完整且无多余用户/权限字段
- [ ] test_health 和 test_database 是真实测试
- [ ] .env、uploads/*、data/*.db 均被忽略
- [ ] .env.example 无真实 Key
- [ ] 没有 Redis/Celery/LangChain 等无关依赖
- [ ] pytest 0 failed
- [ ] Reviewer 允许进入 Task 2

### Task 1 人工冒烟测试

```bash
cd backend
uvicorn app.main:app --reload --port 8000
```

浏览器打开：

```text
http://127.0.0.1:8000/health
```

应看到：

```json
{"status":"ok"}
```

**全部勾选后才进入 Task 2。**

---

# Task 2：上传与创建记录
## A. 主开发指令

```text
只执行 Task 2：上传与创建记录。
实现 POST /api/records。
仅支持 .mp3/.wav/.m4a/.mp4/.mov，单文件最大 500 MB。
stored_filename 必须唯一；保留 original_filename；默认 title 为原文件名去扩展名；新记录 status=uploaded；同名文件不得覆盖。
禁止开发转写、摘要、导出。
完成相关测试与完整 backend pytest，更新 README，独立 commit，不开始 Task 3。
```
## B. Reviewer 指令

先发送上面的“Reviewer 通用前缀”，再追加：

```text
审查真实文件落盘、扩展名与 500MB 校验、唯一文件名、original_filename、默认 title、status=uploaded、同名不覆盖、错误处理与测试真实性。
检查没有提前出现 ASR/LLM/导出。
运行 test_records_api.py 和完整 pytest。
最后明确：是否允许进入 Task 3：YES / NO
```
## C. 你重点看的文件

- `backend/app/api/records.py`
- `backend/app/services/record_service.py`
- `backend/tests/test_records_api.py`
- `uploads/`
- `README.md`

## D. 你的人工验收

- [ ] MP3/MP4 可上传
- [ ] TXT/EXE 被拒绝
- [ ] 上传后本地确有文件
- [ ] 同名文件不覆盖
- [ ] 原始文件名保留
- [ ] 默认标题正确
- [ ] status=uploaded
- [ ] 没有 AI 逻辑
- [ ] pytest 0 failed
- [ ] Reviewer 允许进入 Task 3

**全部勾选后才进入 Task 3。**

---

# Task 3：ASR 与 LLM Provider 接口
## A. 主开发指令

```text
只执行 Task 3。
建立 ASRProvider：transcribe(file_path: str) -> str。
建立 LLMProvider：summarize(transcript: str) -> str。
实现 MockASRProvider 与 MockLLMProvider；自动测试不得访问真实外网。
processing_service 状态必须遵循 uploaded→transcribing→transcribed→summarizing→completed；异常时 failed + error_message。
LLM 失败时已生成 transcript 不得丢失。
禁止实现 Task 4 的 process API。
完成测试、README、独立 commit。
```
## B. Reviewer 指令

先发送上面的“Reviewer 通用前缀”，再追加：

```text
审查 Provider 边界、Mock 行为、状态流、错误保留、业务代码是否绑定某一家厂商 SDK、自动测试是否完全离线。
运行 test_processing_service.py 与完整 pytest；只修 Critical/Important。
最后明确：是否允许进入 Task 4：YES / NO
```
## C. 你重点看的文件

- `backend/app/providers/asr/base.py`
- `backend/app/providers/asr/mock.py`
- `backend/app/providers/llm/base.py`
- `backend/app/providers/llm/mock.py`
- `backend/app/services/processing_service.py`
- `backend/tests/test_processing_service.py`

## D. 你的人工验收

- [ ] ASR 统一 transcribe 接口
- [ ] LLM 统一 summarize 接口
- [ ] 当前为 Mock，不调用真实 API
- [ ] 正常最终 completed
- [ ] transcript/summary 被保存
- [ ] ASR/LLM 失败均 failed
- [ ] LLM 失败不丢 transcript
- [ ] 厂商代码未散落业务层
- [ ] pytest 0 failed
- [ ] Reviewer 允许进入 Task 4

**全部勾选后才进入 Task 4。**

---

# Task 4：处理 API
## A. 主开发指令

```text
只执行 Task 4。
实现 POST /api/records/{id}/process，复用 processing_service。
不存在记录返回 404；本地文件缺失返回明确错误；正常完成 ASR→保存 transcript→LLM→保存 summary，返回完整记录。
禁止 Redis、Celery、消息队列、WebSocket、进度百分比。
使用 Mock Provider 自动测试。
完成测试、README、独立 commit。
```
## B. Reviewer 指令

先发送上面的“Reviewer 通用前缀”，再追加：

```text
审查 process API 是否复用 processing_service，404/文件缺失、completed/transcript/summary、是否引入队列/WebSocket。
运行 records_api + processing_service + 完整 pytest。
最后明确：是否允许进入 Task 5：YES / NO
```
## C. 你重点看的文件

- `backend/app/api/records.py`
- `backend/app/services/processing_service.py`
- `backend/tests/test_records_api.py`
- `backend/tests/test_processing_service.py`

## D. 你的人工验收

- [ ] 上传记录后可 process
- [ ] 最终 completed
- [ ] transcript 有值
- [ ] summary 有值
- [ ] 错误 ID=404
- [ ] 缺本地文件有明确错误
- [ ] 无 Redis/Celery/WebSocket
- [ ] pytest 0 failed
- [ ] Reviewer 允许进入 Task 5

**全部勾选后才进入 Task 5。**

---

# Task 5：历史记录、详情、编辑、删除 API
## A. 主开发指令

```text
只执行 Task 5。
实现 GET /api/records、GET /api/records?q=、GET /api/records/{id}、PATCH /api/records/{id}、DELETE /api/records/{id}。
列表 created_at DESC；q 只搜索 title 且部分匹配。
PATCH 仅 title/summary/transcript，title 不可空。
DELETE 删除 DB；本地文件存在则删除，不存在也应允许删 DB。
禁止分页、标签、文件夹、批量操作。
完成测试、README、独立 commit。
```
## B. Reviewer 指令

先发送上面的“Reviewer 通用前缀”，再追加：

```text
审查排序、title 搜索、详情 404、PATCH 字段与空标题、删除 DB+文件、文件缺失时仍能删除、是否擅自增加分页/标签。
运行完整 pytest。
最后明确：是否允许进入 Task 6：YES / NO
```
## C. 你重点看的文件

- `backend/app/api/records.py`
- `backend/app/services/record_service.py`
- `backend/tests/test_records_api.py`

## D. 你的人工验收

- [ ] 列表倒序
- [ ] 标题部分匹配可搜
- [ ] 详情可查
- [ ] title/summary/transcript 可独立修改
- [ ] 空标题被拒绝
- [ ] 删除 DB 成功
- [ ] 对应文件被删
- [ ] 文件缺失仍可删 DB
- [ ] 无分页/标签/文件夹
- [ ] Reviewer 允许进入 Task 6

**全部勾选后才进入 Task 6。**

---

# Task 6：TXT 与 Markdown 导出
## A. 主开发指令

```text
只执行 Task 6。
实现 GET /api/records/{id}/export/txt 与 /export/md。
内容必须含标题、创建时间、原始文件名、AI 摘要、完整转写；Content-Type 与下载文件名正确。
export_service 单独负责生成内容。
不存在记录 404。
禁止 Word/PDF。
完成测试、README、独立 commit。
```
## B. Reviewer 指令

先发送上面的“Reviewer 通用前缀”，再追加：

```text
审查 TXT/MD 内容结构、中文、Content-Type、下载文件名、404、export_service 边界、是否引入 Word/PDF。
运行 export_service 测试和完整 pytest。
最后明确：是否允许进入 Task 7：YES / NO
```
## C. 你重点看的文件

- `backend/app/services/export_service.py`
- `backend/app/api/records.py`
- `backend/tests/test_export_service.py`

## D. 你的人工验收

- [ ] TXT 能下载且中文正常
- [ ] TXT 含标题/摘要/转写
- [ ] MD 能下载且中文正常
- [ ] MD 有 # 标题、## AI 摘要、## 完整转写
- [ ] 不存在记录 404
- [ ] 无 Word/PDF
- [ ] pytest 0 failed
- [ ] Reviewer 允许进入 Task 7

**全部勾选后才进入 Task 7。**

---

# Task 7：前端基础与路由
## A. 主开发指令

```text
只执行 Task 7。
建立 React + Vite + TypeScript 前端骨架。
只允许三个主路由：/、/history、/records/:id。
页面：UploadPage、HistoryPage、RecordDetailPage。
顶部主导航只有“上传”“历史记录”。
建立 RecordItem 类型与简单 records API 模块。
禁止 Dashboard、Settings、Login、重量级 UI 系统。
npm run build 必须通过；README 更新；独立 commit。
```
## B. Reviewer 指令

先发送上面的“Reviewer 通用前缀”，再追加：

```text
审查技术栈、3 路由、导航、RecordItem 与后端字段、API 模块、是否新增 Dashboard/Login/Settings/大 UI 框架。
运行 npm run build。
最后明确：是否允许进入 Task 8：YES / NO
```
## C. 你重点看的文件

- `frontend/src/App.tsx`
- `frontend/src/pages/UploadPage.tsx`
- `frontend/src/pages/HistoryPage.tsx`
- `frontend/src/pages/RecordDetailPage.tsx`
- `frontend/src/types/record.ts`
- `frontend/src/api/records.ts`

## D. 你的人工验收

- [ ] 三个路由均可打开
- [ ] 无白屏
- [ ] 导航只有上传/历史记录
- [ ] 无登录/仪表盘/设置
- [ ] RecordItem 与后端一致
- [ ] npm run build 成功
- [ ] Reviewer 允许进入 Task 8

**全部勾选后才进入 Task 8。**

---

# Task 8：上传页
## A. 主开发指令

```text
只执行 Task 8。
实现：选择文件→POST /api/records→POST /api/records/{id}/process→成功后进入 /records/{id}。
显示支持格式、500MB、选中文件、处理状态与错误。
未选文件不得提交。
禁止批量上传、复杂拖拽动画、上传百分比。
build 通过；README 更新；独立 commit。
```
## B. Reviewer 指令

先发送上面的“Reviewer 通用前缀”，再追加：

```text
审查两个 API 调用顺序、成功跳详情、未选文件、错误展示、重复点击风险、范围外上传功能。
运行 npm run build。
最后明确：是否允许进入 Task 9：YES / NO
```
## C. 你重点看的文件

- `frontend/src/pages/UploadPage.tsx`
- `frontend/src/api/records.ts`

## D. 你的人工验收

- [ ] 能选小型 MP3
- [ ] 显示文件名
- [ ] 未选不能提交
- [ ] 状态变化可见
- [ ] Mock 流程完成后进入详情
- [ ] 错误可见
- [ ] 无批量/百分比
- [ ] build 成功
- [ ] Reviewer 允许进入 Task 9

**全部勾选后才进入 Task 9。**

---

# Task 9：历史记录页
## A. 主开发指令

```text
只执行 Task 9。
调用 GET /api/records；展示标题、原始文件名、类型、创建时间、状态。
搜索使用 ?q=；点击进详情；支持单条删除与简单确认；删除后刷新列表。
禁止分页、批量删除、标签、文件夹、高级筛选。
build 通过；README 更新；独立 commit。
```
## B. Reviewer 指令

先发送上面的“Reviewer 通用前缀”，再追加：

```text
审查列表字段、?q= 搜索、详情跳转、DELETE 与刷新、错误提示、是否加入分页/批量/标签。
运行 npm run build。
最后明确：是否允许进入 Task 10：YES / NO
```
## C. 你重点看的文件

- `frontend/src/pages/HistoryPage.tsx`
- `frontend/src/api/records.ts`

## D. 你的人工验收

- [ ] 至少 3 条记录正常展示
- [ ] 新记录在前
- [ ] 标题搜索有效
- [ ] 清空搜索恢复
- [ ] 点击进入详情
- [ ] 删除有确认且删除后消失
- [ ] 无分页/标签
- [ ] build 成功
- [ ] Reviewer 允许进入 Task 10

**全部勾选后才进入 Task 10。**

---

# Task 10：详情编辑与导出
## A. 主开发指令

```text
只执行 Task 10。
详情页加载记录；title/summary/transcript 可编辑；PATCH 保存；保存成功提示。
提供 TXT、Markdown 下载；删除记录后返回历史页。
failed 状态显示 error_message；已有 transcript/summary 时仍展示可编辑。
禁止富文本编辑器、Word/PDF。
build 通过；README 更新；独立 commit。
```
## B. Reviewer 指令

先发送上面的“Reviewer 通用前缀”，再追加：

```text
审查详情数据、PATCH 持久化、刷新后仍存在、两种导出、DELETE、failed 状态、是否引入富文本/Word/PDF。
运行 npm run build，并确认 backend pytest 仍通过。
最后明确：是否允许进入 Task 11：YES / NO
```
## C. 你重点看的文件

- `frontend/src/pages/RecordDetailPage.tsx`
- `frontend/src/api/records.ts`

## D. 你的人工验收

- [ ] 标题/摘要/transcript 可编辑保存
- [ ] 刷新后修改仍存在
- [ ] TXT/MD 均可下载且内容正确
- [ ] 删除后返回历史页
- [ ] failed 可显示错误且保留已有内容
- [ ] build 成功
- [ ] backend pytest 通过
- [ ] Reviewer 允许进入 Task 11

**全部勾选后才进入 Task 11。**

---

# Task 11：真实 ASR Provider
## A. 主开发指令

```text
执行 Task 11 前先确认仓库/用户已经明确真实 ASR 服务商。
如果没有明确供应商：不要自行选择，只报告缺口并停止。
若已确定：新增 RealASRProvider，保留 Mock；统一接口 transcribe(file_path)->str；Key 仅环境变量；错误转换清晰；自动测试仍默认 Mock；用 1–5 分钟真实媒体人工验证；只增加实际需要的 env 变量；更新 SOFT_COPYRIGHT.md、README；完整 pytest；独立 commit。
```
## B. Reviewer 指令

先发送上面的“Reviewer 通用前缀”，再追加：

```text
审查 Real/Mock 共存、业务层不被供应商污染、Key 不在 Git/前端/日志、外部错误处理、真实短媒体验证、自动测试仍离线、软著第三方依赖说明。
运行完整 pytest，并检查 git diff/可疑密钥。
最后明确：是否允许进入 Task 12：YES / NO
```
## C. 你重点看的文件

- `backend/app/providers/asr/`
- `backend/app/services/processing_service.py`
- `.env.example`
- `docs/SOFT_COPYRIGHT.md`

## D. 你的人工验收

- [ ] 明确知道 ASR 供应商
- [ ] 真实短音频可转写且不是 Mock 文本
- [ ] .env.example 无真实 Key
- [ ] Git 中无 Key
- [ ] 前端拿不到 Key
- [ ] 失败有明确提示
- [ ] 切回 Mock 测试仍通过
- [ ] pytest 0 failed
- [ ] Reviewer 允许进入 Task 12

**全部勾选后才进入 Task 12。**

---

# Task 12：真实 LLM Provider
## A. 主开发指令

```text
执行 Task 12 前先确认真实 LLM 服务商/模型。
若未明确：不要自行选择，只报告缺口并停止。
若已确定：新增 RealLLMProvider，保留 Mock；实现 summarize(transcript)->str；按 AI_INTEGRATION.md 输出 ## 内容摘要 / ## 核心要点 / ## 待办事项；不得修改 transcript 或直接访问 DB；Key 仅后端环境变量；真实 transcript 验证；更新 env/软著/README；完整 pytest；独立 commit。
```
## B. Reviewer 指令

先发送上面的“Reviewer 通用前缀”，再追加：

```text
审查 Real/Mock 共存、固定三段结构、Prompt 忠实性、不得修改 transcript/DB、Key 安全、失败处理、是否擅自增加聊天/RAG/向量库、自动测试离线。
运行完整 pytest。
最后明确：是否允许进入 Task 13：YES / NO
```
## C. 你重点看的文件

- `backend/app/providers/llm/`
- `docs/AI_INTEGRATION.md`
- `.env.example`
- `docs/SOFT_COPYRIGHT.md`

## D. 你的人工验收

- [ ] 明确 LLM 服务商/模型
- [ ] 真实 transcript 可生成摘要
- [ ] 三段标题齐全
- [ ] 没有明显胡编
- [ ] transcript 未被改
- [ ] Key 未暴露
- [ ] 无聊天/RAG
- [ ] pytest 0 failed
- [ ] Reviewer 允许进入 Task 13

**全部勾选后才进入 Task 13。**

---

# Task 13：端到端验收与软著截图
## A. 主开发指令

```text
只执行 Task 13，不增加任何新功能。
用真实 1–5 分钟媒体完整验证：上传→真实 ASR→真实 LLM→编辑标题/摘要/transcript→保存→历史搜索→重新打开→TXT→Markdown→删除。
整理 docs/screenshots/01-upload.png 至 07-export.png；不得含隐私/API Key/调试报错。
运行 backend pytest -v 与 frontend npm run build。
更新 README 为 1.0.0、SOFT_COPYRIGHT.md；确认文档与实现一致后创建 git tag v1.0.0。
禁止开发 V1.1。
```
## B. Reviewer 指令

先发送上面的“Reviewer 通用前缀”，再追加：

```text
做整个 V1.0 最终审查：逐项核对 PRODUCT_SPEC、检查 TODO/TBD、范围外功能、backend pytest、frontend build、真实 ASR/LLM、编辑/历史/导出/删除、Key 安全、gitignore、README/ARCHITECTURE 一致、screenshots、SOFT_COPYRIGHT。
Critical/Important 仅做最小修复；禁止新增功能。
最终明确“是否允许冻结 V1.0：YES/NO”。
最后明确：是否允许进入 Task V1.0 冻结：YES / NO
```
## C. 你重点看的文件

- `AGENTS.md`
- `README.md`
- `docs/PRODUCT_SPEC.md`
- `docs/ARCHITECTURE.md`
- `docs/SOFT_COPYRIGHT.md`
- `docs/screenshots/`
- `backend/`
- `frontend/`

## D. 你的人工验收

- [ ] 真实上传成功
- [ ] 真实 ASR 转写基本准确
- [ ] 真实摘要三段结构
- [ ] 编辑后刷新仍存在
- [ ] 历史搜索/重新打开正常
- [ ] TXT/MD 正常
- [ ] 删除 DB+本地文件
- [ ] backend pytest 0 failed
- [ ] frontend build 成功
- [ ] Git 无真实 Key
- [ ] 7 张截图完整无隐私
- [ ] README=1.0.0
- [ ] v1.0.0 tag 存在
- [ ] 最终 Reviewer 允许冻结

**全部勾选后：冻结 V1.0，新需求进入 V1.1。**

---

# 出现争议时怎么处理

如果 Reviewer 说有问题，但主开发认为没问题，把 Reviewer 的具体问题复制给主开发：

```text
Reviewer 提出了以下问题：

【粘贴 Reviewer 原话】

不要直接修改代码。

请先判断问题是否真实存在，并给出：
1. 是否存在
2. 原因
3. 受影响文件
4. 可复现方式
5. 最小修复方案
6. 需要运行的测试

不要讨论范围外优化。
```

确认问题成立后再让主开发做最小修复。

---

# 每个 Task 做完但你不确定时

复制：

```text
不要继续开发。

请根据 docs/DEVELOPMENT_PLAN.md 当前 Task 的验收要求逐项列出：

1. 已完成
2. 未完成
3. 测试证据
4. 对应文件
5. 当前 commit SHA

如果有任何未完成项，请明确标记，不要声称 Task 已完成。
```

---

# V1.0 唯一目标

```text
上传音视频
→ 转文字
→ AI摘要
→ 内容编辑
→ 历史记录
→ 导出
```

没有写进 `PRODUCT_SPEC.md` 的功能，默认不做。
