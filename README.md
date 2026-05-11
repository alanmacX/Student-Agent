# Student-Agent (ChatBot) 🚀

> **你的 macOS 个人日程与学习智能管家**

Student-Agent 是一款专为学生设计的 macOS 原生智能应用。它不仅是一个聊天机器人，更是一个拥有多 Agent 协作架构的日程管理系统，旨在整合学习通（Chaoxing）、系统提醒事项、日历以及个人课程表，通过 AI 实现智能化的信息提取与任务规划。

---

## ✨ 核心特性

### 1. 🤖 多智能体协作架构 (Multi-Agent)
项目采用前沿的 Agent 调度设计，各司其职：
- **Main Agent**: 负责与用户直接交互，处理增删改查任务，提供决策支持。
- **Memory Agent**: 后台运行，从繁杂的消息流中提取关键事实，维护长期记忆。
- **Focus Agent**: 每日早起/开启应用时，为你总结未来 48 小时的优先级事务。
- **Companion Agent**: 活在桌面上的“数字宠物”，通过轻量化的气泡与表情与你互动。

### 2. 🎓 深度集成学习通 (Chaoxing)
- **自动同步**: 实时抓取作业、课程变更、考试通知。
- **智能过滤**: 自动识别垃圾信息，仅保留高价值的通知内容。
- **OCR 支持**: 自动识别老师发送的通知图片，将其转化为可搜索、可提醒的任务。

### 3. 📅 智能日程整合
- **全渠道视图**: 统一展示系统 Reminders、Calendar、课程表以及学习通 DDL。
- **自然语言交互**: 支持通过对话“帮我把周四的课推迟一小时”或“总结一下这周的作业”。
- **记忆增强**: 应用会记住你的偏好和历史习惯，提供个性化的建议。

### 4. 🐾 桌面伴侣 (Companion)
- **常驻挂件**: 一个可爱的桌面宠物，实时同步你的同步状态。
- **情绪互动**: 根据你的任务进度和时间点展示不同的状态（如：DDL 临近时的紧迫感）。

---

## 🛠️ 技术栈

- **语言**: Swift 6.0+ (SwiftUI)
- **平台**: macOS 14.0+
- **AI 驱动**: 兼容 OpenAI, Anthropic, Google Gemini 以及小米 MiMo 等多种 Provider
- **架构**: 基于 Reducer 的状态管理 + 异步并发 (Structured Concurrency)
- **本地存储**: UserDefaults + JSON 记忆文件系统

---

## 📂 项目结构

- `ChatBot/`: 核心源码
  - `ChaoxingService.swift`: 学习通协议层集成
  - `ChatViewModel.swift`: 核心业务逻辑与 Agent 调度
  - `CompanionEngine.swift`: 桌面宠物行为逻辑
  - `SKILL_SPEC.md`: Agent 技能与交互规范说明书
- `tools/`: 开发辅助工具

---

## 🚀 快速开始

1. **克隆仓库**:
   ```bash
   git clone https://github.com/alanmacX/Student-Agent.git
打开项目: 使用 Xcode 打开 ChatBot.xcodeproj。
配置 API Key: 在应用的设置界面中，填入你的 OpenAI/Anthropic/Gemini API Key。
登录学习通: 通过应用内的扫码功能完成身份验证。
🛡️ 隐私说明
Student-Agent 高度重视隐私：

所有的 API Key 均存储在本地 Keychain 或 UserDefaults 中，不会上传至第三方服务器（除 AI 供应商接口外）。
学习通的 Cookie 仅用于本地与官方接口通信。
建议在提交代码前检查 .gitignore 以确保个人课程表等数据不被泄露。
📝 许可证

MIT License

### 建议操作：
1. 在你的项目根目录创建一个 `README.md` 文件。
2. 粘贴以上内容。
3. 如果你有桌面宠物的截图，可以在 `## 桌面伴侣` 下方加上 `![Companion](path/to/screenshot.png)`。
