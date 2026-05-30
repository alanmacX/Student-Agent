# Debug Guide for Student-Agent (Web)

**给其他 agent 看的全流程调试指南。** 任何改动前先读 `CODEBASE.md`（项目根目录），本文补充调试细节。

---

## 0. 开始调试前的强制检查

```bash
# 1. 确认本地和服务器一致（如不确定，先同步）
rsync -azn --exclude='node_modules' --exclude='dist' --exclude='__pycache__' \
  aliyun-root:/opt/chatbot/ /Users/macalan/Documents/chatbot/server-src/
# -n = dry run，先看差异，确认后去掉 -n 执行

# 2. 确认容器健康
ssh aliyun-root "docker ps --format '{{.Names}} {{.Status}}'"
# 期望: 3 个容器都是 Up ... (healthy) 或 Up

# 3. 确认后端在线
ssh aliyun-root "docker exec chatbot-backend-1 \
  python3 -c 'import urllib.request; urllib.request.urlopen(\"http://localhost:8000/health\", timeout=3)'"
```

---

## 1. 服务器环境速查

| 项目 | 值 |
|---|---|
| SSH | `aliyun-root` |
| 应用目录 | `/opt/chatbot/` |
| 容器 backend | `chatbot-backend-1` |
| 容器 frontend | `chatbot-frontend-1` |
| 容器 nginx | `chatbot-nginx-1` |
| 数据库 | `/var/lib/docker/volumes/chatbot_chatbot_data/_data/chatbot.db` |
| 钉钉 DB | `/root/.config/DingTalk/<账号目录>/DBFiles/dingtalk.db` (挂载为 `/dingtalk_db/dingtalk.db`) |
| 后端端口 | 8000 (容器内), 通过 nginx 80 对外 |

---

## 2. 日志查看

```bash
# 后端实时日志（最常用）
ssh aliyun-root "docker logs -f --tail 50 chatbot-backend-1"

# 只看错误
ssh aliyun-root "docker logs --tail 200 chatbot-backend-1 2>&1 | grep -i 'error\|exception\|traceback' | head -30"

# nginx 访问日志
ssh aliyun-root "docker logs --tail 50 chatbot-nginx-1"

# 查看特定模块日志（例如钉钉）
ssh aliyun-root "docker logs --tail 300 chatbot-backend-1 2>&1 | grep -i 'dingtalk'"
```

---

## 3. 数据库调试

```bash
DB='sqlite3 /var/lib/docker/volumes/chatbot_chatbot_data/_data/chatbot.db'

# 查表结构
ssh aliyun-root "$DB \".tables\""

# 查 memory 状态
ssh aliyun-root "$DB \
  'SELECT kind, source_type, COUNT(*) as n FROM chaoxing_memory_entries
   WHERE archived_at IS NULL GROUP BY kind, source_type;'"

# 查 settings
ssh aliyun-root "$DB 'SELECT * FROM settings;'"

# 查 pending mutation（confirm button 相关）
ssh aliyun-root "$DB \"SELECT value FROM settings WHERE key='schedule_pending_mutation';\""

# 查钉钉 filter config
ssh aliyun-root "$DB 'SELECT * FROM dingtalk_filter_config;'"

# 在容器内跑 Python 操作 DB
ssh aliyun-root "docker exec chatbot-backend-1 python3 - <<'EOF'
import asyncio, aiosqlite, json
async def main():
    async with aiosqlite.connect('/data/chatbot.db') as db:
        db.row_factory = aiosqlite.Row
        rows = await (await db.execute('SELECT * FROM settings')).fetchall()
        for r in rows: print(dict(r))
asyncio.run(main())
EOF"
```

---

## 4. 后端代码调试

### 4.1 改单个 Python 文件

```bash
# 本地改好后，compile 验证
python3 -m py_compile server-src/backend/app/path/to/file.py

# 上传 + 注入容器 + 验证 + 重启
scp server-src/backend/app/path/to/file.py aliyun-root:/tmp/file.py
ssh aliyun-root "
  docker cp /tmp/file.py chatbot-backend-1:/app/app/path/to/file.py
  docker exec chatbot-backend-1 python3 -m py_compile /app/app/path/to/file.py && echo 'compile OK'
  docker restart chatbot-backend-1
  sleep 5
  docker logs --tail 5 chatbot-backend-1 2>&1
"
```

### 4.2 验证 API 端点

```bash
# 从服务器内部访问（不走 nginx）
IP=$(ssh aliyun-root "docker inspect -f '{{.NetworkSettings.Networks.chatbot_default.IPAddress}}' chatbot-backend-1")
ssh aliyun-root "curl -s http://$IP:8000/health"
ssh aliyun-root "curl -s http://$IP:8000/api/dingtalk/status | python3 -m json.tool"

# 走 nginx（测试完整路径）
ssh aliyun-root "curl -s http://localhost/api/dingtalk/filter-config | python3 -m json.tool"
```

### 4.3 在容器内跑测试代码

```bash
ssh aliyun-root "docker exec -i chatbot-backend-1 python3 << 'EOF'
import sys; sys.path.insert(0, '/app')
from app.dingtalk.filters import evaluate
msg = {'cid': 'test', 'conversation_title': '算法班', 'content_type': 1, 'text': '明天作业截止！'}
print(evaluate(msg)['verdict'])
EOF"
```

---

## 5. 前端调试

### 5.1 改前端文件

```bash
# 在 server-src/frontend/src/ 里改好后
cd server-src/frontend
npx vite build 2>&1 | tail -8      # 看 bundle hash 和大小

# 部署
tar czf /tmp/fe.tar.gz -C dist .
scp /tmp/fe.tar.gz aliyun-root:/tmp/
ssh aliyun-root "
  docker exec chatbot-frontend-1 sh -c 'rm -rf /usr/share/nginx/html/*'
  docker cp /tmp/fe.tar.gz chatbot-frontend-1:/tmp/fe.tar.gz
  docker exec chatbot-frontend-1 sh -c 'cd /usr/share/nginx/html && tar xzf /tmp/fe.tar.gz && rm /tmp/fe.tar.gz'
  curl -s http://localhost/ | grep -o 'index-[A-Za-z0-9_-]*\.js'   # 确认新 hash
"
```

### 5.2 验证 bundle 内容

```bash
# 确认某字符串在 bundle 里
ssh aliyun-root "docker exec chatbot-frontend-1 \
  grep -c 'DingTalk\|filter-config' /usr/share/nginx/html/assets/index-*.js"

# 查 bundle hash（对比本地 dist/ 和线上）
ls server-src/frontend/dist/assets/
ssh aliyun-root "ls /usr/share/nginx/html/assets/"
```

### 5.3 前端 PWA 缓存问题

Service worker 会缓存旧资源。强制清除：
1. 手机端：关闭 App → Safari/Chrome 设置 → 清除网站数据 → 重新打开
2. 或在 DevTools → Application → Service Workers → Unregister
3. 代码里 `sw.js` 有版本号，更新版本号会触发强制刷新

---

## 6. 同步规则（必须遵守）

### 改动后的同步顺序

```
本地 server-src/ 改动
  → python3 -m py_compile 或 npm run build 验证
  → scp 上传到 /opt/chatbot/ 对应路径
  → docker cp 注入容器（或 docker restart）
  → 验证线上正常
  → git add + git commit + git push（最后同步 repo）
```

### 从服务器拉最新代码到本地

```bash
# 完整同步（--delete 会删掉本地有、服务器没有的文件）
rsync -az --exclude='node_modules' --exclude='dist' --exclude='__pycache__' \
  --exclude='.env' \
  aliyun-root:/opt/chatbot/ /Users/macalan/Documents/chatbot/server-src/

# 只同步某个文件
scp aliyun-root:/opt/chatbot/backend/app/services/schedule_agent.py \
    server-src/backend/app/services/schedule_agent.py
```

### 检查本地 vs 服务器是否一致

```bash
# 批量 hash 比较（替换 file.py 为要检查的文件）
for f in services/schedule_agent.py memory/base.py dingtalk/filters.py; do
  LOCAL=$(md5 -q server-src/backend/app/$f 2>/dev/null)
  SRV=$(ssh aliyun-root "docker exec chatbot-backend-1 md5sum /app/app/$f 2>/dev/null | cut -d' ' -f1")
  [ "$LOCAL" = "$SRV" ] && echo "OK:   $f" || echo "DIFF: $f"
done
```

### Git 同步

```bash
# 改动后提交（只提交 server-src/ 相关，不要提交 .env、DB 等）
git add server-src/ CODEBASE.md README.md
git add -u   # 已跟踪文件的修改
git commit -m "描述改动"
git push origin main
```

---

## 7. 各模块调试入口

### 7.1 学习通（Chaoxing）

```bash
# 检查登录状态
ssh aliyun-root "docker exec chatbot-backend-1 python3 - <<'EOF'
import asyncio, sys; sys.path.insert(0, '/app')
from app.services.chaoxing_service import ChaoxingService
from app.config import settings
svc = ChaoxingService(settings.database_path)
asyncio.run(svc._load_session())
print('logged_in:', svc.is_logged_in)
EOF"

# 手动触发一次 memory 同步
curl -s http://localhost/api/chaoxing/trigger-sync  # 如存在该端点

# 查 chaoxing memory 状态
ssh aliyun-root "sqlite3 /var/lib/docker/volumes/chatbot_chatbot_data/_data/chatbot.db \
  'SELECT kind, COUNT(*), MAX(updated_at) FROM chaoxing_memory_entries
   WHERE source_type=\"chaoxing\" AND archived_at IS NULL GROUP BY kind;'"
```

### 7.2 钉钉（DingTalk）

```bash
# 检查解密是否正常（需要 pycryptodome）
ssh aliyun-root "docker exec chatbot-backend-1 python3 -c \
  'from app.dingtalk.dingtalk_service import decrypt_db_to_tmp; print(decrypt_db_to_tmp())'"

# 手动触发同步
ssh aliyun-root "curl -s -X POST http://\$(docker inspect -f '{{.NetworkSettings.Networks.chatbot_default.IPAddress}}' chatbot-backend-1):8000/api/dingtalk/sync"

# 查 filter config
ssh aliyun-root "docker exec chatbot-backend-1 python3 -c \"
import asyncio, sys; sys.path.insert(0, '/app')
from app.dingtalk.filters import load_filter_config, _filter_config
asyncio.run(load_filter_config('/data/chatbot.db'))
print(_filter_config)
\""
```

### 7.3 日程 Agent + 确认按钮

```bash
# 查 pending mutation（按钮消失时先检查这个）
ssh aliyun-root "sqlite3 /var/lib/docker/volumes/chatbot_chatbot_data/_data/chatbot.db \
  \"SELECT value FROM settings WHERE key='schedule_pending_mutation';\""

# 清空 pending（重置按钮状态）
ssh aliyun-root "sqlite3 /var/lib/docker/volumes/chatbot_chatbot_data/_data/chatbot.db \
  \"DELETE FROM settings WHERE key='schedule_pending_mutation';\""
```

### 7.4 Memory 系统

```bash
# 查各来源 memory 数量
ssh aliyun-root "sqlite3 /var/lib/docker/volumes/chatbot_chatbot_data/_data/chatbot.db \"
SELECT source_type, kind, hierarchy_tier, COUNT(*) as n
FROM chaoxing_memory_entries WHERE archived_at IS NULL
GROUP BY source_type, kind, hierarchy_tier ORDER BY source_type, kind;\""

# 触发 memory sweep
ssh aliyun-root "docker exec chatbot-backend-1 python3 -c \"
import asyncio, sys; sys.path.insert(0, '/app')
from app.memory.base import MemoryRepository
from datetime import datetime, timezone
async def main():
    r = MemoryRepository('/data/chatbot.db')
    result = await r.sweep(datetime.now(timezone.utc))
    print(result)
asyncio.run(main())
\""
```

---

## 8. 常见问题

### 后端启动失败

```bash
ssh aliyun-root "docker logs chatbot-backend-1 2>&1 | grep -A5 'Error\|Exception\|Traceback' | head -30"
# 常见原因：ImportError（缺依赖）、SyntaxError（代码错误）、DB 锁
```

### pycryptodome 缺失（钉钉解密失败）

```bash
ssh aliyun-root "docker exec chatbot-backend-1 pip install -i https://mirrors.aliyun.com/pypi/simple/ pycryptodome"
# 永久修复：已写入 backend/requirements.txt，下次 docker build 自动包含
```

### 前端显示旧版本

1. 确认 bundle hash 和本地 `dist/assets/` 一致
2. 清除 PWA 缓存（见 5.3）
3. 检查 nginx 没有额外缓存：`curl -I http://server/assets/index-*.js | grep cache`

### 容器 OOM / 崩溃

```bash
ssh aliyun-root "docker stats --no-stream chatbot-backend-1"
ssh aliyun-root "docker inspect chatbot-backend-1 | grep -A5 OomKillDisable"
```

### DB locked

```bash
# 找占用 DB 的进程
ssh aliyun-root "docker exec chatbot-backend-1 lsof /data/chatbot.db 2>/dev/null"
# 通常 docker restart 即可解决
ssh aliyun-root "docker restart chatbot-backend-1"
```

---

## 9. 完整重建（核武器，谨慎使用）

```bash
# 不删数据（推荐）
ssh aliyun-root "cd /opt/chatbot && docker compose down && docker compose up -d --build"

# 删数据重来（会丢失所有会话、memory、学习通登录态）
ssh aliyun-root "cd /opt/chatbot && docker compose down -v && docker compose up -d --build"
```

重建后手动恢复的数据：
- 课程表：`course_schedule_backup.json`（在本地 repo 根目录）
- 学习通登录态：重新扫码
- pycryptodome：`docker exec chatbot-backend-1 pip install pycryptodome`（已在 requirements.txt，重建后自动包含）

---

## 10. 设计约束（不要违反）

- **Memory 写入**：必须通过 `MemoryRepository.upsert_entry()`，禁止直接 `INSERT INTO chaoxing_memory_entries`
- **DingTalk filter**：三阶段（Stage 0 用户配置 → Stage 1 确定性硬屏蔽 → Stage 2 LLM）；不要短路 Stage 2
- **前端唯一源**：`server-src/frontend/src/`；不要改 `/opt/chatbot/components/`（已删除）
- **Pending confirmation**：改 `ScheduleView.jsx` 时注意 `pendingConfirmRef` 必须在 `onDone` async await 之后重新附加
- **改动链**：本地改 → 编译验证 → 部署服务器 → 验证线上 → git commit → git push
