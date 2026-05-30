# DingTalk extraction package

This folder is self-contained and is not wired into `app.main` or
`app.tasks.scheduler` yet.

## Host smoke tests

Run from `/opt/chatbot` on the server:

```bash
PYTHONPATH=/opt/chatbot/backend python3 -m app.dingtalk.sync --once
```

Poll every 30 seconds:

```bash
PYTHONPATH=/opt/chatbot/backend python3 -m app.dingtalk.sync --poll --interval 30
```

The host default chatbot DB path is detected in this order:

1. `CHATBOT_DB_PATH`
2. `/data/chatbot.db`
3. `/var/lib/docker/volumes/chatbot_chatbot_data/_data/chatbot.db`
4. `/var/lib/docker/volumes/chatbot_data/_data/chatbot.db`
5. `app.config.settings.database_path`

## Future FastAPI integration

When ready to wire this into the running app:

1. Add `pycryptodome` to `backend/requirements.txt`.
2. Mount the host DingTalk DB directory read-only into the backend container.
3. Include `app.dingtalk.router.router` in `app.main`.
4. Add `app.dingtalk.sync.run_dingtalk_sync` to the global scheduler.

