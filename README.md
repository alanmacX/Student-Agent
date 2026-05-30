# Student-Agent (ChatBot Web)

一个为学生设计的个人 AI 日程管家，以 Docker 自托管部署，通过浏览器或手机访问。

**核心能力**：学习通作业/消息自动同步 → Memory AI 提炼 → 钉钉消息监听 → 智能日程 Agent 对话 → Web Push 通知。

---

## 快速部署（Linux 服务器）

### 前置要求

- Docker + Docker Compose v2
- 公网服务器（用于接收 Web Push，本地部署也可用，但推送不可用）
- 域名（可选，HTTPS 必须，否则 PWA 推送不可用）

### 1. 克隆仓库

```bash
git clone https://github.com/alanmacX/Student-Agent.git /opt/chatbot
cd /opt/chatbot/server-src
```

### 2. 一键安装

```bash
bash install.sh
```

安装脚本会交互式引导你完成：
- LLM Provider 和 Model 配置
- Web Push VAPID 密钥生成（可选）
- 钉钉消息监听配置（可选，含 Xvfb、客户端安装、systemd 注册）

如跳过钉钉：
```bash
bash install.sh --no-dingtalk
```

如需指定端口（默认 80）：
```bash
bash install.sh --port 8080
```

安装完成后访问 `http://your-server:80`。

### 3. 配置 Provider

进入 **Settings → Provider**，添加你的 API Key（支持 OpenAI / Anthropic / Gemini / 任意兼容接口）。

---

## 学习通（Chaoxing）接入

进入 **Settings → 学习通**，扫码登录。登录后每 5 分钟自动同步一次作业和消息，AI 自动提炼重要内容写入 Memory。

---

## 钉钉接入（可选）

钉钉功能通过读取钉钉 Linux 客户端的本地 SQLite 数据库实现（只读，不需要开放 API）。

运行 `install.sh` 时选择启用钉钉即可自动完成以下所有步骤。如需手动配置，参考下方。

### 手动配置步骤

**1. 安装依赖**

```bash
apt-get install -y xvfb x11-utils imagemagick libgtk-3-0 libnss3 libxss1 libasound2 libgbm1
```

**2. 安装钉钉 Linux 客户端**

从 [钉钉官网](https://page.dingtalk.com/wow/dingtalk/act/download) 下载 Linux 版安装。

**3. 首次登录**

启动 Xvfb 虚拟显示器，然后启动钉钉，通过 VNC/noVNC 连接 `:99` 扫码登录：

```bash
Xvfb :99 -screen 0 1280x800x24 &
export DISPLAY=:99
/opt/apps/com.alibabainc.dingtalk/files/*/com.alibabainc.dingtalk --no-sandbox
```

**4. systemd 服务**

项目提供了预配置的 systemd 服务文件（`systemd/` 目录），`install.sh` 会自动安装。手动安装：

```bash
cp systemd/*.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now dingtalk-xvfb dingtalk dingtalk-qr
```

**5. 验证**

进入 **Settings → 钉钉**，点击"立即同步"。WAL 更新时间表示钉钉客户端仍在活跃写入。

---

## 目录结构

```
server-src/
├── backend/              Python FastAPI 后端
│   ├── app/
│   │   ├── routers/      HTTP 路由层
│   │   ├── services/     业务逻辑
│   │   ├── memory/       统一 Memory 层
│   │   ├── chaoxing/     学习通集成
│   │   ├── dingtalk/     钉钉集成
│   │   └── tasks/        APScheduler 定时任务
│   ├── Dockerfile
│   └── requirements.txt
├── frontend/             React + Vite 前端
│   ├── src/
│   └── Dockerfile
├── install.sh            一键安装脚本
├── upgrade.sh            升级脚本
├── docker-compose.yml
└── nginx.conf
```

---

## 更新部署

```bash
cd /opt/chatbot
bash server-src/upgrade.sh
```

或手动：

```bash
cd /opt/chatbot && git pull
cd server-src && docker compose up -d --build
```

---

## 常见问题

**Q: 学习通登录后没有同步数据？**
A: 等待 5 分钟（默认 sync interval）。可在 Settings → 学习通 手动触发同步并查看状态。

**Q: 钉钉显示"客户端未运行"？**
A: 检查 dingtalk systemd 服务状态：`systemctl status dingtalk`。WAL 文件超过 5 分钟未更新说明钉钉进程已退出。

**Q: Web Push 收不到通知？**
A: HTTPS 是必须条件。VAPID 密钥需要正确配置，且用户需在浏览器授权通知权限。

**Q: 如何重置数据库？**
A: `docker volume rm chatbot_chatbot_data` 后重启即可（会清除所有会话记录和 Memory）。
