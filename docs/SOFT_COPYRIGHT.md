# AI 智能会议纪要与内容管理系统 V1.0 — 软件著作权材料留存规范

> 本文档用于开发过程中的材料整理，不代替正式登记机关的最新申报要求。正式提交前应再次核对当时的官方要求。

## 1. 目的

开发过程中同步保留能够说明软件独立开发过程、功能、代码结构和 V1.0 完成状态的材料。

避免软件开发完以后再反向拼凑：

- 源代码
- 操作说明
- 界面截图
- 版本信息
- 开发记录
- 第三方依赖说明

---

## 2. 软件暂定信息

### 软件全称

```text
AI智能会议纪要与内容管理系统
```

### 版本

```text
V1.0
```

### 软件简称

```text
AI会议纪要系统
```

正式申请前统一核对名称，之后不要在代码、说明书、截图中出现多个不同软件名称。

---

## 3. V1.0 核心功能描述

软件完成以下流程：

```text
音视频上传
→ 文件管理
→ 语音转文字
→ AI摘要
→ 文本编辑
→ 历史记录
→ TXT/Markdown导出
```

功能描述应与：

- `PRODUCT_SPEC.md`
- 实际软件
- 操作截图
- 最终申请材料

保持一致。

---

## 4. 开发过程需要保留

### Git

建议从项目第一天使用 Git。

每个任务完成后做小提交。

示例提交信息：

```text
chore: initialize backend
feat: add media upload
feat: add transcription provider
feat: add summary provider
feat: add record history
feat: add record editing
feat: add txt and markdown export
feat: complete frontend upload flow
fix: handle provider failure
docs: prepare v1.0 screenshots
```

V1.0 最终：

```text
git tag v1.0.0
```

不要为了申报伪造不存在的历史提交。

---

## 5. 源代码留存

整个 V1.0 项目源代码应完整保存。

至少包含：

```text
frontend/src/
backend/app/
```

申请准备阶段另外生成一个只用于整理/打印的代码材料版本。

整理源代码时：

不得包含：

- API Key
- 密码
- `.env`
- 用户真实隐私数据
- 第三方密钥
- 无关 node_modules
- 虚拟环境
- 编译缓存

优先使用能够体现自主功能逻辑的代码：

- 上传
- 数据模型
- 处理状态
- Provider 抽象
- AI 调用适配
- 内容编辑
- 历史记录
- 搜索
- 导出

---

## 6. 页面截图

V1.0 最终验收时至少保存：

```text
docs/screenshots/01-upload.png
docs/screenshots/02-processing.png
docs/screenshots/03-detail.png
docs/screenshots/04-edit.png
docs/screenshots/05-history.png
docs/screenshots/06-search.png
docs/screenshots/07-export.png
```

截图要求：

- 界面完整
- 软件名称一致
- 不暴露 API Key
- 不出现调试报错
- 尽量使用虚构测试数据
- 能清楚证明功能存在

如最终界面变化，应重新截图，不保留明显过时图片作为正式材料。

---

## 7. 用户操作说明书素材

开发过程中同步记录实际操作。

建议最终操作说明书结构：

```text
1. 软件概述
2. 运行环境
3. 系统主要功能
4. 软件启动
5. 上传音视频
6. 语音转写
7. AI摘要
8. 内容编辑
9. 历史记录与搜索
10. TXT导出
11. Markdown导出
12. 删除记录
13. 常见错误
```

每一个章节使用最终 V1.0 页面截图。

不要描述 V1.0 中不存在的功能。

---

## 8. 架构说明材料

保存：

- 前后端结构
- SQLite 数据模型
- 本地文件存储
- ASR Provider
- LLM Provider
- API 列表

主要来源：

```text
docs/ARCHITECTURE.md
```

这份文档应始终跟实际代码同步。

---

## 9. 第三方与开源依赖说明

使用第三方框架和 API 不等于第三方拥有本项目整体业务代码。

但应清楚区分：

### 项目自己实现

- 页面流程
- 上传逻辑
- 记录管理
- 数据模型
- 状态管理
- 编辑逻辑
- 历史记录
- 搜索
- 导出
- Provider 适配逻辑

### 第三方依赖

例如：

```text
React
Vite
FastAPI
SQLAlchemy
第三方 ASR API
第三方 LLM API
```

不要复制第三方项目大量源代码作为本项目主体。

不要把第三方 SDK 源码计算为自己开发代码。

### 当前外部 AI 能力依赖

V1.0 的语音转文字能力接入科大讯飞录音文件转写标准版 Web API。该服务仅作为外部 ASR 能力依赖；本项目自行实现 Provider 适配、上传记录、处理状态、数据持久化、编辑、历史记录、搜索和导出等业务逻辑。

仓库不包含科大讯飞服务端代码、真实 AppID、SecretKey 或用户媒体数据，也不把第三方服务能力声明为本项目自主实现的算法。

---

## 10. AI 辅助开发记录

本项目允许使用 Codex 等 AI 辅助编程工具。

为了保证项目可维护和可说明：

- 开发者应实际决定产品功能和架构。
- AI 生成代码必须经过阅读和测试。
- 不接受无法解释的大段代码。
- 不直接复制来源不明的完整商业软件代码。
- 每项功能通过测试后再进入主分支。
- 保留项目自己的需求文档、架构文档和提交记录。

如果 Codex 生成了明显超出需求的模块，应删除，而不是因为已经生成就保留。

---

## 11. 权属需要提前确认

如果软件用于公司业务，正式登记前应确认：

- 开发主体
- 著作权人
- 是否属于职务开发
- 是否使用公司资源
- 是否存在书面约定

不要等软件完成并准备申报时才第一次讨论权属。

如以个人名义申请，同时提供公司使用，建议把实际开发、授权和权属关系用书面方式留存并依法处理。

---

## 12. 版本冻结

满足以下条件后冻结 V1.0：

- 六项核心功能完成
- 后端测试全部通过
- 前端 Build 通过
- 真实 ASR/LLM 流程至少验证一次
- 操作截图完成
- README 版本记录更新
- Git tag `v1.0.0`

冻结后：

- 不再给 V1.0 增加功能
- 新需求进入 V1.1
- 软著材料以被冻结的 V1.0 为准

这样可以避免申请材料与正在持续变化的软件不一致。

---

## 13. V1.0 最终材料清单

开发完成时至少应拥有：

```text
完整项目源代码
AGENTS.md
README.md
PRODUCT_SPEC.md
ARCHITECTURE.md
DEVELOPMENT_PLAN.md
TESTING.md
AI_INTEGRATION.md
SOFT_COPYRIGHT.md
最终页面截图
Git 提交历史
v1.0.0 标签
可实际运行的软件
一份最终用户操作说明素材
```

以上材料用于后续整理，不代表需要全部原样提交。
