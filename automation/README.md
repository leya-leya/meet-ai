# 自动化开发流水线

本目录为项目提供 Windows PowerShell 优先、单 Task 串行的 Codex 自动开发流水线。它不改变 V1.0 产品范围，也不属于产品运行时。

## 1. 新流程

```text
选择下一个依赖已完成的 TODO Task
→ 新 Developer Agent（workspace-write）
→ automation/test.ps1 客观测试
→ 新 Reviewer Agent（read-only + JSON Schema）
→ PASS：安全检查 → DONE 状态随当前 Task 一次 Git commit → 下一个普通 Task
→ FIX：新 Fixer Agent → 测试 → 新 Reviewer，最多两轮
→ BLOCKED：保留现场、写报告、停止
→ Milestone 最后一个 Task：写阶段报告、停止等待人工验收
```

Developer、Reviewer、Fixer 每次都是新的 `codex exec`，不复用对话。Reviewer 默认只读，不能修改代码。流程控制只属于 `autodev.ps1`。

## 2. 第一次运行

先在普通 Windows PowerShell 中确认项目工作区和 Codex CLI：

```powershell
git status
codex --version
codex exec --help
.\automation\autodev.ps1 -DryRun
```

当前 V1.0 的 Task 1–13 已全部完成并冻结，因此第一次 DryRun 会显示“无待执行 Task”，不会重新修改业务代码。未来在 `docs/DEVELOPMENT_PLAN.md` 增加明确 Task 后，再把对应的轻量状态条目加入 `automation/state/tasks.json`。

真实 Task 启动前，工作区内不得存在 `.env` / `.env.*`（`.env.example` 除外），因为 workspace-write Agent 能读取项目文件。需要保留的真实凭据应先放到启动 PowerShell 的进程环境并移走本地 `.env`；Agent 子进程仍会剥离项目 AI 凭据，客观测试强制使用 Mock。

开始或继续自动开发：

```powershell
.\automation\autodev.ps1
```

## 3. 常用参数

```powershell
# 从 IN_PROGRESS / REVIEW / FIXING / BLOCKED 的受信现场继续
.\automation\autodev.ps1 -Resume

# 只执行指定的未完成 Task
.\automation\autodev.ps1 -Task "TASK-014"

# 完成测试与审查但不自动提交；状态停在 REVIEW
.\automation\autodev.ps1 -NoCommit

# 只展示选择、测试、Agent 权限和停止条件；不修改文件、不提交
.\automation\autodev.ps1 -DryRun

# 自动修复轮数只能为 0–2，默认 2
.\automation\autodev.ps1 -MaxFixRounds 1

# 人工修复了 BLOCKED 代码，或 Agent/暂存阶段被硬中断后，显式接受现场并重新全测/Review
.\automation\autodev.ps1 -Resume -Task "TASK-014" -AcceptHumanChanges
```

可选模型覆盖：

```powershell
$env:AUTODEV_DEV_MODEL = "<已配置且当前 CLI 支持的模型>"
$env:AUTODEV_REVIEW_MODEL = "<已配置且当前 CLI 支持的模型>"
```

默认不传 `--model`，完全沿用用户当前 Codex provider、认证和模型配置。脚本不会修改 `~/.codex/config.toml`。

## 4. Task 与 Resume 状态

- 产品需求与 Acceptance Criteria 的唯一真相源：`docs/DEVELOPMENT_PLAN.md`，并受 `PRODUCT_SPEC.md`、`ARCHITECTURE.md` 等规范约束。
- 机器运行状态：`automation/state/tasks.json`。
- 每项状态只保存 `id`、`title`、`status`、`depends_on`、`milestone`、`source` 及最后状态信息，不复制产品需求正文。
- 合法状态：`TODO`、`IN_PROGRESS`、`REVIEW`、`FIXING`、`DONE`、`BLOCKED`。
- `source` 必须指向开发计划中的 Task 标题；编排器会确认该 Task 至少有目标和验收/验证/测试标准。
- 同一时间最多一个活动 Task。依赖未完成、多个活动 Task 或状态非法都会 BLOCKED。
- 受信运行现场写入 Git 元数据目录 `.git/autodev/current-run.json`，workspace-write Agent 无权修改；代码、测试和报告都不会被 reset/clean。

人工只修复环境或外部条件、没有改代码时，运行 `.\automation\autodev.ps1 -Resume -Task "TASK-XXX"`。脚本会校验 Task、基准 HEAD、原始 `MaxFixRounds`、累计 Fix 轮次、报告目录和最后一个受信工作区指纹；中断后若出现额外修改会拒绝普通 Resume。若 BLOCKED 的解决方案包含人工代码修改，或宿主在 Agent/暂存阶段被硬中断导致指纹不一致，使用显式 `-AcceptHumanChanges`；编排器会先做安全检查和审计记录，再强制重新运行完整客观测试及新的 Reviewer。无需手工改写 Task 状态。

## 5. 测试

统一入口：

```powershell
.\automation\test.ps1
```

依次运行：

```text
backend/.venv/Scripts/python.exe -m pytest -v
npm test
npm run build
```

最后一项同时执行 TypeScript typecheck 和 Vite build。项目当前没有独立 lint 命令，因此脚本不会伪造 lint 成功。自动测试强制使用 Mock ASR/LLM，不访问真实外部 AI。

pytest 的临时文件使用 `automation/state/test-temp/<GUID>`，避免受管 Windows 环境的用户 Temp ACL 影响；脚本只清理本次创建且绝对路径确认位于该目录下的临时文件。

后端测试把 Python bytecode cache 重定向到本轮临时目录；前端测试前只在绝对路径确认位于 `frontend/node_modules` 后清除 `.vite` / `.cache`，build 前删除两个明确的、可再生的 `tsconfig.*.tsbuildinfo`，避免 ignored cache 伪造增量成功。`.venv` 与 `node_modules` 的非缓存文件在 Task 开始时生成完整 SHA256 指纹，每个 Agent 前后、测试前后和 commit 前都会复核；自动 Task 不允许改写测试裁判运行时。

客观测试不是由编排器裸执行：脚本现场检测并要求 Codex CLI 支持 `sandbox windows --full-auto`，再在无 Git 元数据写权限、受限网络的 Windows sandbox 中启动 `test.ps1`。测试子进程移除所有名称含 key/secret/token/password/credential 的环境变量，并临时强制 Mock Provider、本地 SQLite、临时 uploads 与 TEMP/TMP；无论成功或失败都会恢复环境并清理本轮目录。Developer、Reviewer、Fixer 子进程也会移除项目的 `ASR_APP_ID`、`ASR_SECRET_KEY`、`LLM_API_KEY`，但保留 Codex 自身认证环境。测试和 CLI 输出在写盘前会遮蔽常见 Token 与 secret/password/api-key 键值。

测试前后还会核对 HEAD、index tree、Git config、受信 run-state、整个报告树、测试 runtime、控制面和工作区指纹。任一测试尝试改写 Git、报告、依赖运行时或项目文件都会 BLOCKED，不会被当作测试成功。

任何测试命令非零退出都视为失败；AI 无权覆盖测试结论。

## 6. Reviewer 协议

Reviewer 必须输出 `schemas/review-result.schema.json` 定义的 JSON：

```json
{
  "verdict": "PASS",
  "summary": "Task implementation meets requirements.",
  "issues": []
}
```

`verdict` 只允许 `PASS`、`FIX`、`BLOCKED`。P0/P1 存在时不能 PASS；测试失败时编排器也会强制转为 FIX。Reviewer JSON 无法解析、字段非法或协议矛盾时，流水线安全停止。

## 7. Git 规则

只有同时满足下列条件才提交：

```text
统一测试 exit 0
+ Reviewer PASS
+ 无 .env/密钥特征
+ 无未合并文件
+ 无异常大规模删除
```

提交前会记录 `git status`、`git diff --stat` 并再次扫描 staged diff。默认提交格式：

```text
feat: complete TASK-XXX <title>
```

编排器不会执行 `git reset --hard`、`git clean -fd`、stash、历史改写或自动 push。

编排器只暂存最终 Reviewer 实际审过的路径集合，不使用无边界的 `git add --all`。无法完整审查的未跟踪大文本或任何非图片二进制会 BLOCKED（即使 Agent 提前暂存也不能绕过）；允许的图片资产上限为 5 MB，并把尺寸、SHA256 和工作区路径交给 Reviewer 检查。

`.gitignore`、`docs/PRODUCT_SPEC.md`、`autodev.ps1`、`test.ps1`、核心模块、角色 Prompt、Reviewer Schema、所有 `AGENTS.md`、`.codex/**` 和当前 Task 的 Acceptance Source 构成控制面。新 Task 开始时它们必须与 HEAD 一致；每个 Agent 返回或超时后都会重新校验路径集合与启动前哈希。自动 Task 不允许修改产品范围或控制面，流水线自身升级必须像本次改造一样由人工发起、独立审查和提交。

Reviewer PASS 会同时锁定路径集合与文件内容指纹；暂存前、暂存后和 commit 前都会复核。最终 commit 还会核对 index tree 与实际 committed tree，避免同路径后台改写、文件 watcher 或 Git hook 把未审内容带入提交。

## 8. 日志与报告

每次真实 Task 运行创建：

```text
automation/reports/YYYY-MM-DD_HHMMSS_TASK-XXX/
```

包含适用的：

```text
developer.md
test-before-review.txt
review-1.json
fix-1.md
test-after-fix-1.txt
review-2.json
pre-commit-status.txt
summary.md
BLOCKED_REPORT.md
MILESTONE_REPORT.md
resume.txt
human-rebaseline.md
```

运行报告被 `.gitignore` 忽略，只保留目录占位文件。写日志前会遮蔽常见 Token；diff 在交给 Reviewer 前先做密钥特征检查。仍不得主动在 Agent 输出、测试或报告中打印环境变量和凭据。

整个 `automation/reports`（不只当前 Task）的完整文件树指纹保存在 Agent 无权写入的受信 run-state 中；每个 Agent 前后都会复核全部既有报告，编排器每次合法写报告后才更新 checkpoint，避免后续 Task 的 Agent 静默改删前序日志。

## 9. BLOCKED 与安全边界

以下情况停止而不猜测：需求/验收矛盾、依赖未完成、状态或 Git 异常、用户未提交修改与新任务冲突、真实密钥/付费服务缺失、生产访问、部署、破坏性迁移或大范围删除、第三方行为无法确认、Reviewer BLOCKED、Reviewer JSON 非法、测试基础设施无法安全运行、Codex CLI 失败/超时、Git commit 失败、两轮 Fix 后仍未 PASS。

自动化只允许当前工作区、开发/测试环境、本地数据库、Mock 和 fixture。它不使用 `danger-full-access` 或 bypass sandbox，不连接生产数据库/SSH，不部署 production，不进行真实支付、邮件、短信或用户数据操作。

## 10. Milestone

Milestone 及其最后一个 Task 定义在 `tasks.json`。当前划分：

- M1：Task 1–3，后端基础与 AI 抽象
- M2：Task 4–6，后端业务 API 闭环
- M3：Task 7–10，前端完整业务流程
- M4：Task 11–13，真实 AI 与 V1.0 冻结

完成 `gate_after_task` 后自动停止并生成 `MILESTONE_REPORT.md`，不会跨越人工验收节点。

## 11. Codex CLI 兼容策略

每次真实运行现场执行 `codex --version`、`codex exec --help`，并探测 `codex sandbox windows --help`。仅在帮助文本明确支持时启用 `--ephemeral`、`--output-last-message`、`--output-schema` 和可选 `--model`；Agent 的 `--sandbox` 与客观测试的 Windows `--full-auto` sandbox 都是安全必需能力。这里的 `--full-auto` 是本地 workspace-write / 网络隔离策略，不是 `danger-full-access` 或 bypass。没有 `--output-schema` 时仍要求 Reviewer 只输出 JSON，再由本地解析器严格校验。

官方参考：[Codex developer commands](https://developers.openai.com/codex/cli/reference)。
