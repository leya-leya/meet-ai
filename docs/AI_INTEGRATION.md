# AI 智能会议纪要与内容管理系统 V1.0 — AI 接入规范

## 1. 目标

V1.0 使用外部 AI 服务完成两项能力：

1. ASR：音视频 → 文字
2. LLM：文字 → 摘要

项目本身负责业务流程、文件管理、数据管理、编辑、历史记录和导出。

第三方 AI 服务只作为能力提供者。

---

## 2. 核心原则

业务层不得直接写：

```text
某厂商 SDK client.xxx()
```

而应只调用项目自己的接口：

```python
transcribe(file_path: str) -> str
```

和：

```python
summarize(transcript: str) -> str
```

这样以后更换供应商时，不修改主要业务流程。

---

## 3. ASR Provider

抽象接口语义：

```python
class ASRProvider:
    def transcribe(self, file_path: str) -> str:
        ...
```

要求：

输入：

```text
本地媒体文件路径
```

输出：

```text
纯文本 transcript
```

Provider 内部负责：

- 读取/上传文件
- 调用第三方接口
- 必要的轮询
- 从第三方响应中提取纯文字
- 把厂商异常转换成项目异常

Provider 不负责：

- 保存数据库
- 修改 Record 状态
- 生成摘要
- 修改前端

---

## 4. LLM Provider

抽象接口语义：

```python
class LLMProvider:
    def summarize(self, transcript: str) -> str:
        ...
```

输入：

```text
完整 transcript
```

输出：

```text
Markdown 字符串
```

必须包含：

```markdown
## 内容摘要

## 核心要点

## 待办事项
```

---

## 5. 推荐摘要 Prompt

V1.0 使用固定、简单 Prompt，不做复杂 Prompt 工程。

System 意图：

```text
你是企业内部会议与音视频内容整理助手。
你的任务是忠实整理输入文本，不虚构输入中不存在的信息。
输出必须使用简体中文 Markdown。
```

User Prompt 意图：

```text
请根据以下转写文本生成结构化摘要。

要求：
1. 保留事实，不虚构。
2. 输出必须包含以下三个二级标题：
   ## 内容摘要
   ## 核心要点
   ## 待办事项
3. 内容摘要控制在数段以内。
4. 核心要点使用项目符号。
5. 只有文本中存在明确行动项时才提取待办；
   如果没有明确待办，写“无明确待办事项”。
6. 不要输出额外说明。

转写文本：
{transcript}
```

不得让 LLM：

- 自动修改原 transcript
- 自动删除数据库记录
- 自动调用其他系统
- 自动发布内容

---

## 6. 长文本策略

V1.0 不提前实现复杂分块摘要系统。

第一版策略：

1. 将完整 transcript 直接提交给 LLM。
2. 如果实际供应商上下文窗口不足，记录真实错误。
3. 只有真实测试确认经常超限后，才允许在 V1.1 设计分块摘要。

不要因为“未来可能会很长”提前引入：

- MapReduce 摘要
- 向量数据库
- RAG
- 文本嵌入
- 分布式任务

---

## 7. Provider 配置

环境变量：

```env
ASR_PROVIDER=mock
ASR_API_KEY=

LLM_PROVIDER=mock
LLM_API_KEY=
```

可以增加具体供应商需要的：

```env
ASR_BASE_URL=
ASR_MODEL=

LLM_BASE_URL=
LLM_MODEL=
```

但只有实际 Provider 使用时再增加。

不要预先增加十几个供应商变量。

---

## 8. Mock Provider

自动测试默认：

```env
ASR_PROVIDER=mock
LLM_PROVIDER=mock
```

Mock ASR：

```text
这是一段用于自动化测试的转写文本。
```

Mock LLM：

```markdown
## 内容摘要

这是一段用于自动化测试的摘要。

## 核心要点

- 测试要点

## 待办事项

- 无明确待办事项
```

这样测试完全不依赖外网。

---

## 9. 错误处理

建议项目级异常：

```text
ASRProviderError
LLMProviderError
```

错误信息必须适合记录到：

```text
record.error_message
```

但不要记录：

- API Key
- Authorization Header
- 完整敏感请求头

可记录：

- Provider 名称
- HTTP 状态码
- 简短厂商错误信息
- 当前 record id

---

## 10. 密钥安全

真实 Key：

- 只存在 `.env`
- 后端读取
- 不返回前端
- 不打印日志
- 不进入 Git

`.env.example`：

```env
ASR_PROVIDER=mock
ASR_API_KEY=
LLM_PROVIDER=mock
LLM_API_KEY=
```

---

## 11. 成本控制

开发阶段：

- 自动测试全部 Mock
- 真实测试用 1–5 分钟媒体
- 不重复对同一长文件调用 AI

V1.0 不开发复杂成本统计页面。

---

## 12. 接入新 Provider 的标准流程

只允许按以下步骤：

1. 保留现有 Provider 接口。
2. 新建供应商实现文件。
3. 写 Provider 级测试，外部请求可以 Mock。
4. 更新环境变量读取。
5. 使用真实短文件人工验证一次。
6. 确认 `processing_service` 无需修改或只做最小配置修改。
7. 更新 `docs/SOFT_COPYRIGHT.md` 中外部依赖说明。

如果接入一个新供应商必须重写大部分业务代码，说明 Provider 边界设计有问题，应先修边界，不要复制一套业务逻辑。
