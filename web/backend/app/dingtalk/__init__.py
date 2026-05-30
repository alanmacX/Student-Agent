"""Self-contained DingTalk extraction package.

This package is intentionally not wired into app.main or the global scheduler
yet. Use ``python -m app.dingtalk.sync --once`` or ``--poll`` to run it from
the host while the container integration is being prepared.
"""

