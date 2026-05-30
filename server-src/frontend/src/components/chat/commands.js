import { AlarmClock, StickyNote, Activity, Trash2 } from "lucide-react";

const COMMANDS = [
  {
    name: "/remind",
    label: "新建提醒",
    hint: "创建一个提醒事项",
    icon: AlarmClock,
    usage: "/remind 提醒内容",
  },
  {
    name: "/note",
    label: "快速笔记",
    hint: "保存到 Hub 便签",
    icon: StickyNote,
    usage: "/note 笔记内容",
  },
  {
    name: "/status",
    label: "服务器状态",
    hint: "查看系统健康状态",
    icon: Activity,
    usage: "/status",
  },
  {
    name: "/clear",
    label: "清空对话",
    hint: "开始新对话",
    icon: Trash2,
    usage: "/clear",
  },
];

export default COMMANDS;

export function filterCommands(query) {
  if (!query) return COMMANDS;
  const lower = query.toLowerCase();
  return COMMANDS.filter(
    (c) => c.name.includes(lower) || c.label.includes(lower) || c.hint.includes(lower)
  );
}
