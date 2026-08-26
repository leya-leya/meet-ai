# AI 智能会议纪要与内容管理系统 V1.0 — 测试规范

## 1. 测试目标

测试的目标不是追求高覆盖率数字，而是保证 V1.0 核心闭环不会被改坏。

必须重点保护：

```text
上传
→ 创建记录
→ 转写
→ 摘要
→ 编辑
→ 搜索
→ 导出
→ 删除
```

---

## 2. 后端测试工具

使用：

```text
pytest
FastAPI TestClient
临时 SQLite 数据库
临时上传目录
Mock ASR Provider
Mock LLM Provider
```

自动测试不得依赖真实外部 AI API。

原因：

- 避免费用
- 避免网络波动
- 避免 API 限流
- 测试结果可复现

---

## 3. 测试隔离

每个测试应使用独立：

- 临时数据库
- 临时上传目录

测试后清理。

不得让自动测试写入正式：

```text
data/app.db
uploads/
```

---

## 4. 必测模块

### 4.1 Health

```http
GET /health
```

断言：

```json
{"status":"ok"}
```

---

### 4.2 上传

正常：

- mp3
- wav
- m4a
- mp4
- mov

异常：

- exe
- txt
- 不带文件
- 超过大小限制

重点断言：

- 记录存在
- `status == uploaded`
- 原文件名正确
- 内部文件名唯一
- 文件确实保存

---

### 4.3 Processing Service

正常流程断言：

```text
uploaded
→ completed
```

最终：

```text
transcript != null
summary != null
error_message == null
```

ASR 失败：

```text
status == failed
error_message != null
```

LLM 失败：

```text
transcript != null
status == failed
error_message != null
```

注意：

LLM 失败时已经产生的 transcript 不得丢失。

---

## 5. CRUD

必须测试：

### List

- 创建多个记录
- 返回顺序为 newest first

### Search

标题：

```text
"周三直播复盘"
```

搜索：

```text
"直播"
```

应该匹配。

搜索原始文件名但标题不匹配时，不要求命中。

### Detail

不存在 ID：

```text
404
```

### Update

支持部分更新：

```json
{"title":"新标题"}
```

或：

```json
{"summary":"新摘要"}
```

空标题：

```json
{"title":""}
```

必须拒绝。

### Delete

断言：

- DB 中不存在
- 文件被删除

如果文件事先被手工删除：

- API 仍成功
- DB 记录删除

---

## 6. 导出

准备固定记录：

```text
title = "测试会议"
summary = "这是摘要"
transcript = "这是转写"
```

TXT 断言：

- 响应成功
- 包含“测试会议”
- 包含“这是摘要”
- 包含“这是转写”

Markdown 断言：

- 包含 `# 测试会议`
- 包含 `## AI 摘要`
- 包含 `## 完整转写`

---

## 7. 前端最低验证

V1.0 不要求建立复杂前端测试体系。

最低要求：

```bash
npm run build
```

必须通过。

开发关键交互时可增加轻量测试，但不得为了测试框架本身扩大项目复杂度。

手工检查：

### 上传页

- 支持格式可见
- 选择文件正常
- 未选择不能提交
- API 错误可见
- 成功进入详情

### 历史页

- 列表可见
- 搜索可用
- 详情跳转可用
- 删除可用

### 详情页

- 标题可编辑
- 摘要可编辑
- 转写可编辑
- 保存可用
- 导出可用
- 删除可用

---

## 8. 回归测试

自动化流水线统一执行：

```powershell
.\automation\test.ps1
```

该入口依次运行完整后端 pytest、前端 Vitest 和包含 TypeScript typecheck 的前端 build；任一命令非零即整体非零。项目当前没有独立 lint 命令，因此不伪造 lint 结果。

每完成一个后端 Task：

```bash
cd backend
pytest -v
```

如果总测试耗时已经明显变长，至少运行：

```bash
pytest 当前相关测试文件 -v
```

在 Task 13 最终验收时必须运行完整：

```bash
pytest -v
```

前端每次主要修改后运行：

```bash
npm run build
```

---

## 9. 真实 AI 测试

真实 ASR 和 LLM 不属于普通自动测试。

只做少量人工集成验证。

固定使用一个短测试媒体文件：

```text
1–5 分钟
```

检查：

- ASR 返回非空文本
- 文本基本对应原音频
- LLM 返回固定三段结构
- 失败时系统没有崩溃
- API Key 没有暴露到浏览器

不要用长达一两个小时的视频作为开发阶段常规测试输入。

---

## 10. Bug 修复规则

发现 Bug 时：

1. 先确认能稳定复现。
2. 如果适合自动化测试，先增加失败测试。
3. 只修复根因。
4. 运行相关测试。
5. 再运行受影响模块回归测试。

禁止：

- 为修一个 Bug 重写整个模块
- 用 try/except 吞掉错误
- 删除失败测试来让 CI 通过

---

## 11. V1.0 最终测试清单

后端：

```bash
pytest -v
```

前端：

```bash
npm run build
```

人工 E2E：

```text
上传
→ 转写
→ 摘要
→ 编辑
→ 保存
→ 搜索
→ 打开
→ TXT
→ Markdown
→ 删除
```

三项都通过才可以打 `v1.0.0`。
