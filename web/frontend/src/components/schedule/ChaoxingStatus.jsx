import { useState, useEffect, useRef } from "react";
import { LogOut, Loader2, QrCode, RefreshCw, CheckCircle2, Brain, ClipboardList, Activity, Wifi, WifiOff } from "lucide-react";
import { chaoxingLogout, getChaoxingStatus, pollQrLogin, startQrLogin } from "../../api/chaoxing";
import { fetchScheduleSidebar } from "../../api/schedule";

export default function ChaoxingStatus() {
  const [status, setStatus] = useState({ logged_in: false });
  const [qr, setQr] = useState(null);
  // idle | loading | waiting | scanned | confirming | confirmed | expired | failed
  const [qrState, setQrState] = useState("idle");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const timerRef = useRef(null);

  useEffect(() => {
    getChaoxingStatus().then(setStatus).catch(console.error);
  }, []);

  // Polling effect — runs while waiting or scanned
  useEffect(() => {
    if (status.logged_in || !qr || !["waiting", "scanned"].includes(qrState)) return;

    const poll = async () => {
      try {
        const result = await pollQrLogin(qr.uuid, qr.enc);

        if (result.status === "confirmed") {
          // Stop polling immediately
          if (timerRef.current) {
            window.clearInterval(timerRef.current);
            timerRef.current = null;
          }
          setQrState("confirming"); // show "正在登录..." while we fetch status

          // Retry getChaoxingStatus a few times — the backend needs a moment to finalize
          let attempts = 0;
          const checkLogin = async () => {
            attempts++;
            try {
              const s = await getChaoxingStatus();
              if (s.logged_in) {
                setStatus(s);
                setQrState("confirmed");
              } else if (attempts < 5) {
                setTimeout(checkLogin, 1200);
              } else {
                // Give up and just trust is_logged_in was set
                setStatus({ logged_in: true, uid: s.uid });
                setQrState("confirmed");
              }
            } catch {
              if (attempts < 3) setTimeout(checkLogin, 1500);
            }
          };
          checkLogin();
        } else if (result.status === "failed") {
          setError(result.message || "登录失败");
          setQrState("failed");
        } else if (result.status) {
          setQrState(result.status);
        }
      } catch (e) {
        setError(e.message);
        setQrState("failed");
      }
    };

    timerRef.current = window.setInterval(poll, 2500);
    return () => {
      if (timerRef.current) {
        window.clearInterval(timerRef.current);
        timerRef.current = null;
      }
    };
  }, [qr, qrState, status.logged_in]);

  const handleStartQr = async () => {
    setLoading(true);
    setError("");
    setQrState("loading");
    try {
      const session = await startQrLogin();
      if (session.error) {
        setError(session.error);
        setQrState("failed");
      } else {
        setQr(session);
        setQrState("waiting");
      }
    } catch (e) {
      setError(e.message);
      setQrState("failed");
    } finally {
      setLoading(false);
    }
  };

  const handleLogout = async () => {
    await chaoxingLogout();
    setStatus({ logged_in: false });
    setQr(null);
    setQrState("idle");
  };

  if (status.logged_in) {
    return (
      <div className="max-w-md space-y-4">
        <h2 className="text-lg font-semibold text-white">学习通</h2>
        <div className="rounded-2xl border border-green-500/30 bg-green-500/10 p-4">
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-3">
              <CheckCircle2 size={20} className="shrink-0 text-green-400" />
              <div>
                <p className="text-sm font-medium text-green-300">已登录</p>
                {status.username && <p className="text-xs text-[var(--text-tertiary)]">{status.username}</p>}
                {status.uid && <p className="text-xs text-[var(--text-tertiary)]">UID: {status.uid}</p>}
              </div>
            </div>
            <button
              onClick={handleLogout}
              className="flex min-h-10 items-center gap-1 rounded-2xl bg-[var(--hover-bg)] px-3 text-sm hover:bg-[var(--hover-bg-strong)]"
            >
              <LogOut size={14} />
              退出
            </button>
          </div>
        </div>

        {/* Health info */}
        <HealthInfo />
      </div>
    );
  }

  return (
    <div className="max-w-md space-y-4">
      <h2 className="text-lg font-semibold text-white">学习通 扫码登录</h2>
      <p className="text-sm leading-6 text-[var(--text-secondary)]">
        使用学习通 App 扫码登录，用于课程、作业和消息 memory。
      </p>

      {error && (
        <div className="rounded-2xl border border-red-500/30 bg-red-500/10 px-3 py-2 text-sm text-red-300">
          {error}
        </div>
      )}

      <div className="space-y-3">
        <div className="grid min-h-[248px] place-items-center rounded-2xl border border-[var(--border)] bg-[var(--surface)] p-4">
          {qr?.image_data_url && ["waiting", "scanned"].includes(qrState) ? (
            <div className="relative overflow-hidden rounded-2xl bg-white p-3">
              <img src={qr.image_data_url} alt="学习通登录二维码" className="h-52 w-52" />
              {qrState === "scanned" && (
                <div className="absolute inset-0 grid place-items-center bg-black/50 text-center text-sm font-semibold text-white">
                  已扫码，请在手机上确认
                </div>
              )}
            </div>
          ) : qrState === "confirming" ? (
            <div className="text-center">
              <Loader2 size={36} className="mx-auto mb-3 animate-spin text-green-400" />
              <p className="text-sm font-semibold text-white">正在登录...</p>
              <p className="mt-1 text-xs text-[var(--text-tertiary)]">验证中，请稍候</p>
            </div>
          ) : qrState === "confirmed" ? (
            <StatusBlock icon={CheckCircle2} title="登录成功" detail="欢迎回来" iconClass="text-green-400" />
          ) : qrState === "expired" ? (
            <StatusBlock icon={RefreshCw} title="二维码已过期" detail="请刷新后重新扫码" />
          ) : qrState === "failed" ? (
            <StatusBlock icon={RefreshCw} title="登录失败" detail={error || "请重试"} />
          ) : qrState === "loading" ? (
            <Loader2 size={32} className="animate-spin text-[var(--accent-soft)]" />
          ) : (
            <StatusBlock icon={QrCode} title="等待生成二维码" detail="点击下方按钮开始" />
          )}
        </div>

        {qrState === "waiting" && (
          <p className="text-center text-sm text-[var(--text-secondary)]">请使用学习通 App 扫描二维码</p>
        )}
        {qrState === "scanned" && (
          <p className="text-center text-sm text-amber-300">请在手机上点击确认登录</p>
        )}
        {qrState === "confirming" && (
          <p className="text-center text-sm text-green-300">正在获取登录凭证...</p>
        )}

        {!["confirming", "confirmed"].includes(qrState) && (
          <button
            onClick={handleStartQr}
            disabled={loading || qrState === "loading"}
            className="flex min-h-11 w-full items-center justify-center gap-2 rounded-2xl bg-[var(--accent)] px-4 text-sm font-semibold text-white transition hover:bg-[var(--accent-strong)] disabled:opacity-50"
          >
            {loading ? <Loader2 size={14} className="animate-spin" /> : <QrCode size={14} />}
            {["expired", "failed"].includes(qrState) ? "刷新二维码" : "生成二维码"}
          </button>
        )}
      </div>
    </div>
  );
}

function StatusBlock({ icon: Icon, title, detail, iconClass = "text-[var(--accent-soft)]" }) {
  return (
    <div className="text-center">
      <Icon size={42} className={`mx-auto mb-3 ${iconClass}`} />
      <p className="text-sm font-semibold text-white">{title}</p>
      <p className="mt-1 text-xs text-[var(--text-tertiary)]">{detail}</p>
    </div>
  );
}

function HealthInfo() {
  const [health, setHealth] = useState(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    fetchScheduleSidebar()
      .then(setHealth)
      .catch(console.error)
      .finally(() => setLoading(false));
  }, []);

  if (loading) {
    return (
      <div className="rounded-2xl border border-[var(--border)] bg-[var(--surface)] p-4">
        <p className="text-xs text-[var(--text-tertiary)]">加载健康信息...</p>
      </div>
    );
  }

  if (!health) return null;

  const activeAssignments = (health.assignments || []).filter(
    (a) => (a.status === "未交" || a.status === "未提交") && a.dueDate
  );
  const memoryCount = (health.memory_insights || []).length;
  const courseCount = (health.local_courses || []).length + (health.courses || []).length;

  return (
    <div className="rounded-2xl border border-[var(--border)] bg-[var(--surface)] p-4 space-y-3">
      <p className="text-xs font-semibold uppercase tracking-widest text-[var(--text-tertiary)]">系统健康</p>
      <div className="grid grid-cols-2 gap-3">
        <HealthCard
          icon={<Wifi size={14} className="text-green-400" />}
          label="连接状态"
          value="正常"
        />
        <HealthCard
          icon={<Brain size={14} className="text-purple-400" />}
          label="Memory"
          value={`${memoryCount} 条`}
        />
        <HealthCard
          icon={<ClipboardList size={14} className="text-pink-400" />}
          label="待交作业"
          value={`${activeAssignments.length} 项`}
        />
        <HealthCard
          icon={<Activity size={14} className="text-blue-400" />}
          label="课程"
          value={`${courseCount} 门`}
        />
      </div>
    </div>
  );
}

function HealthCard({ icon, label, value }) {
  return (
    <div className="rounded-xl bg-[var(--deep-bg)] px-3 py-2">
      <div className="flex items-center gap-1.5 mb-1">
        {icon}
        <span className="text-[11px] text-[var(--text-tertiary)]">{label}</span>
      </div>
      <p className="text-sm font-semibold text-white">{value}</p>
    </div>
  );
}
