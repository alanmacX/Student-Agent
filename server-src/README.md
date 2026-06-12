# Student-Agent Server

这里是部署目录：Docker Compose、FastAPI 后端、React 前端、Nginx 配置和运维脚本都在这里。

完整 v2 架构说明见仓库根目录 `README.md`。

## 安装

```bash
cd /opt/chatbot/server-src
bash install.sh
```

## 升级

```bash
cd /opt/chatbot
bash server-src/upgrade.sh
```

默认流程：拉取代码 -> 从当前源码构建 backend/frontend -> `docker compose up -d` -> 检查 `/health` 和 `/api/dashboard/today`。

可选参数：

- `--skip-pull`
- `--skip-build`
- `--pull-images`
- `--no-healthcheck`

## 验证

```bash
python3 -m compileall backend/app
cd frontend && npm run build
cd ..
BASE_URL=http://localhost ACCESS_TOKEN=xxx python3 scripts/token_compare.py
```

## 关键入口

- `backend/app/services/schedule_agent.py`：主 Schedule Agent。
- `backend/app/services/tool_router.py`：light tool router。
- `backend/app/services/agent_data_tools.py`：只读数据库查询工具。
- `backend/app/services/dashboard_v2.py`：dashboard payload/hash/briefing。
- `backend/app/services/time_utils.py`：统一时间解析和 UTC 归一。
- `scripts/token_compare.py`：真实 SSE token 对比脚本。
