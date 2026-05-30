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
git clone https://github.com/alanmacX/Student-Agent.git
cd Student-Agent/server-src
```

### 2. 创建 .env

```bash
cp .env.example .env
```

编辑 `.env`：

```env
# 必填
DATABASE_PATH=/data/chatbot.db

# 用于 Memory AI 提取和日程 Agent 的 LLM（支持 OpenAI 兼容接口）
STANDBY_AGENT_PROVIDER=openai
STANDBY_AGENT_MODEL=gpt-4o-mini

# Web Push（可选，没有则无推送通知）
VAPID_PRIVATE_KEY=
VAPID_PUBLIC_KEY=
VAPID_MAILTO=mailto:you@example.com
```

VAPID 密钥生成：
```bash
pip install py-vapid
python3 -c "from py_vapid import Vapid; v = Vapid(); v.generate_keys(); print('PRIVATE:', v.private_key()); print('PUBLIC:', v.public_key())"
```

### 3. 启动

```bash
docker compose up -d --build
```

服务启动后访问 `http://your-server:80`。

### 4. 配置 Provider

进入 **Settings → Provider**，添加你的 API Key（支持 OpenAI / Anthropic / Gemini / 任意兼容接口）。

---

## 学习通（Chaoxing）接入

进入 **Settings → 学习通**，扫码登录。登录后每 5 分钟自动同步一次作业和消息，AI 自动提炼重要内容写入 Memory。

---

## 钉钉接入（可选，较复杂）

钉钉功能通过读取钉钉 Linux 客户端的本地 SQLite 数据库实现（只读，不需要开放 API）。

### 前提

服务器需要运行钉钉 Linux 桌面客户端，通过 Xvfb 虚拟显示器运行（无需真实屏幕）。

### 步骤

**1. 安装依赖**

```bash
apt-get install -y xvfb x11-utils libgtk-3-0 libnss3 libxss1 libasound2
```

**2. 安装钉钉 Linux 客户端**

从 [https://page.dingtalk.com/wow/dingtalk/act/download](https://page.dingtalk.com/wow/dingtalk/act/download) 下载 Linux 版，或直接：

```bash
# 阿里云服务器可用官方源
# 下载地址以官网最新版为准
wget -O dingtalk.deb "https://dtapp-pub.dingtalk.com/dingtalk-desktop/xc_dingtalk_update/linux_deb/Release/com.alibabainc.dingtalk_7.6.55-Release.2410312_amd64.deb"
dpkg -i dingtalk.deb
```

**3. 首次登录（需要图形界面操作一次）**

```bash
# 启动虚拟显示器
Xvfb :99 -screen 0 1280x800x24 &
export DISPLAY=:99

# 启动钉钉（登录后 Ctrl+C，之后用 systemd 守护）
/opt/apps/com.alibabainc.dingtalk/files/*/com.alibabainc.dingtalk
```

用 VNC 或 noVNC 连接 `:99` 完成扫码登录。

**4. 设置 systemd 守护**

创建 `/etc/systemd/system/dingtalk.service`：

```ini
[Unit]
Description=DingTalk Client (headless)
After=network.target

[Service]
User=root
Environment=DISPLAY=:99
ExecStartPre=/usr/bin/Xvfb :99 -screen 0 1280x800x24
ExecStart=/opt/apps/com.alibabainc.dingtalk/files/<版本号>/com.alibabainc.dingtalk
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl enable dingtalk
systemctl start dingtalk
```

**5. 配置 docker-compose.yml**

确认钉钉数据库路径（账号目录名因账号而异）：
```bash
ls ~/.config/DingTalk/
# 找类似 <你的账号hash>_v3 的目录
```

在 `docker-compose.yml` 的 backend volumes 里确认路径正确：
```yaml
volumes:
  - /root/.config/DingTalk/<你的账号目录>/DBFiles:/dingtalk_db:ro
```

**6. 安装解密依赖**

钉钉数据库使用 AES 加密，需要 `pycryptodome`。由于该依赖暂未写入 requirements.txt，需手动安装：

```bash
docker exec chatbot-backend-1 pip install --no-cache-dir pycryptodome
```

> **注意**：每次 `docker compose up --build` 重建镜像后，此步骤需要重做。
> 永久解决方法：在 `backend/requirements.txt` 末尾添加 `pycryptodome`。

**7. 验证**

进入 **Settings → 钉钉**，点击"立即同步"，查看状态卡片。WAL 更新时间表示钉钉客户端仍在活跃写入。

---

## 目录结构

```
server-src/
├── backend/              Python FastAPI 后端
│   ├── app/
│   │   ├── routers/      HTTP 路由层
│   │   ├── services/     业务逻辑
│   │   ├── memory/       统一 Memory 层（MemoryRepository + Engine）
│   │   ├── chaoxing/     学习通 Memory 集成
│   │   ├── dingtalk/     钉钉集成
│   │   └── tasks/        APScheduler 定时任务
│   ├── Dockerfile
│   └── requirements.txt
├── frontend/             React + Vite 前端
│   ├── src/
│   └── Dockerfile
├── docker-compose.yml
└── nginx.conf
```

详细架构说明见 [CODEBASE.md](CODEBASE.md)。

---

## 更新部署

**前端改动**（在 `server-src/frontend/src/` 修改后）：
```bash
cd server-src/frontend && npm run build
tar czf /tmp/dist.tar.gz -C dist .
scp /tmp/dist.tar.gz your-server:/tmp/
ssh your-server "
  docker exec chatbot-frontend-1 sh -c 'rm -rf /usr/share/nginx/html/*'
  docker cp /tmp/dist.tar.gz chatbot-frontend-1:/tmp/dist.tar.gz
  docker exec chatbot-frontend-1 sh -c 'cd /usr/share/nginx/html && tar xzf /tmp/dist.tar.gz'
"
```

**后端改动**（修改单个 py 文件后）：
```bash
scp server-src/backend/app/path/to/file.py your-server:/tmp/file.py
ssh your-server "
  docker cp /tmp/file.py chatbot-backend-1:/app/app/path/to/file.py
  docker exec chatbot-backend-1 python3 -m py_compile /app/app/path/to/file.py
  docker restart chatbot-backend-1
"
```

---

## 常见问题

**Q: 学习通登录后没有同步数据？**
A: 等待 5 分钟（默认 sync interval）。可在 Settings → 学习通 手动触发同步并查看状态。

**Q: 钉钉显示"客户端未运行"？**
A: 检查 dingtalk systemd 服务状态：`systemctl status dingtalk`。WAL 文件超过 5 分钟未更新说明钉钉进程已退出。

**Q: 钉钉显示同步 0 条消息？**
A: 先确认 `pycryptodome` 已安装（见上）。`docker logs chatbot-backend-1 2>&1 | grep -i crypto`。

**Q: Web Push 收不到通知？**
A: HTTPS 是必须条件。VAPID 密钥需要正确配置，且用户需在浏览器授权通知权限。

**Q: 如何重置数据库？**
A: `docker volume rm chatbot_chatbot_data` 后重启即可（会清除所有会话记录和 Memory）。
