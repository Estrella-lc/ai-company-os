
"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
type Agent = {
  id: string;
  code: string;
  name: string;
  title: string;
  model_provider: string;
  model_name: string;
  is_active: boolean;
};

const navItems = [
  "CEO 总部",
  "AI高管团队",
  "内部会议室",
  "项目管理",
  "任务中心",
  "审批中心",
  "成本与预算",
  "系统设置",
];

export default function Home() {
  const router = useRouter();
  const [active, setActive] = useState("CEO 总部");
  const [agents, setAgents] = useState<Agent[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [selected, setSelected] = useState("");
  const [instruction, setInstruction] = useState("");

  useEffect(() => {
    async function loadAgents() {
      try {
        setLoading(true);
        setError("");

        const response = await fetch("/api/agents", {
          cache: "no-store",
        });

        const result = await response.json();

        if (!response.ok || !result.success) {
          throw new Error(
            result.error || "无法读取AI高管资料"
          );
        }

        setAgents(result.agents);

        if (result.agents.length > 0) {
          setSelected(result.agents[0].code);
        }
      } catch (err) {
        setError(
          err instanceof Error
            ? err.message
            : "系统连接失败"
        );
      } finally {
        setLoading(false);
      }
    }

    loadAgents();
  }, []);

  const activeAgents = agents.filter(
    (agent) => agent.is_active
  );

  return (
    <main className="min-h-screen bg-[#0b1020] text-slate-100 flex">

      {/* Sidebar */}
      <aside className="w-64 shrink-0 border-r border-slate-800 p-5 hidden md:block">
        <div className="text-xl font-bold tracking-wide mb-2">
          ◈ AI COMPANY
        </div>

        <p className="text-xs text-slate-500 mb-10">
          VIRTUAL ENTERPRISE OS
        </p>

        <p className="text-xs text-slate-500 mb-3">
          MANAGEMENT
        </p>

        <nav className="space-y-2">
          {navItems.map((item) => (
            <button
              key={item}
              onClick={() => setActive(item)}
              className={`w-full text-left rounded-xl px-3 py-3 text-sm ${
                active === item
                  ? "bg-blue-600 text-white"
                  : "text-slate-400 hover:bg-slate-800"
              }`}
            >
              {item}
            </button>
          ))}
        </nav>

        <div className="mt-12 border-t border-slate-800 pt-5">
          <p className="text-xs text-slate-500">
            CEO ACCOUNT
          </p>
          <p className="mt-2 font-medium">
            Founder / CEO
          </p>
          <p className="text-xs text-emerald-400 mt-1">
            ● Authenticated
          </p>
        </div>
      </aside>

      {/* Main content */}
      <section className="flex-1 min-w-0 p-5 md:p-9">

        <header className="flex flex-wrap justify-between items-center gap-4 mb-9">
          <div>
            <p className="text-sm text-slate-500">
              AI COMPANY OS / MANAGEMENT
            </p>

            <h1 className="text-3xl font-bold mt-2">
              {active}
            </h1>

            <p className="text-sm text-slate-400 mt-2">
              欢迎回来，CEO。这里是你的AI公司控制中心。
            </p>
          </div>

          <span className="text-xs border border-emerald-500/40 text-emerald-400 rounded-full px-4 py-2">
            DATABASE CONNECTED
          </span>
        </header>

        {/* Overview */}
        <div className="grid grid-cols-2 xl:grid-cols-4 gap-4 mb-9">

          {[
            ["AI核心角色", loading ? "..." : String(agents.length), "数据库真实记录"],
            ["在职Agent", loading ? "..." : String(activeAgents.length), "已启用角色"],
            ["预算上限", "¥200", "人民币"],
            ["模型状态", "MOCK", "尚未接入真实模型"],
          ].map(([label, value, detail]) => (
            <div
              key={label}
              className="bg-[#151e32] border border-slate-800 rounded-2xl p-5"
            >
              <p className="text-sm text-slate-400">
                {label}
              </p>

              <h2 className="text-2xl font-bold mt-3">
                {value}
              </h2>

              <p className="text-xs text-slate-500 mt-2">
                {detail}
              </p>
            </div>
          ))}

        </div>

        {/* Agent list */}
        <div className="flex justify-between items-center mb-4">
          <h2 className="text-xl font-semibold">
            AI高管团队
          </h2>

          <span className="text-xs text-slate-500">
            DATABASE AGENTS
          </span>
        </div>

        {loading && (
          <div className="bg-[#151e32] rounded-2xl p-8 text-center text-slate-400">
            正在读取Supabase中的AI高管资料...
          </div>
        )}

        {error && (
          <div className="border border-red-500/40 bg-red-500/10 rounded-xl p-5 text-red-300">
            数据读取失败：{error}
            <button
              onClick={() => window.location.reload()}
              className="block mt-3 underline"
            >
              重新加载
            </button>
          </div>
        )}

        {!loading && !error && (
          <div className="grid grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-4">

            {agents.map((agent) => (
              <button
                key={agent.id}
                onClick={() => {
                  setSelected(agent.code);
                  router.push(`/chat/${agent.code}`);
                }}
                className={`text-left p-5 rounded-2xl border transition ${
                  selected === agent.code
                    ? "border-blue-500 bg-blue-500/10"
                    : "border-slate-800 bg-[#151e32] hover:border-slate-600"
                }`}
              >
                <div className="text-blue-400 font-bold text-lg">
                  {agent.code}
                </div>

                <div className="font-medium mt-2">
                  {agent.title}
                </div>

                <div className="text-xs text-slate-500 mt-2">
                  {agent.name}
                </div>

                <div className="text-xs mt-4">
                  {agent.is_active ? (
                    <span className="text-emerald-400">
                      ● 已启用
                    </span>
                  ) : (
                    <span className="text-slate-500">
                      ○ 已停用
                    </span>
                  )}
                </div>

                <div className="text-xs text-amber-400 mt-2">
                  模型：{agent.model_provider}
                </div>
              </button>
            ))}

          </div>
        )}

        {/* CEO command area */}
        <div className="mt-9 bg-[#151e32] border border-slate-800 rounded-2xl p-6">

          <h2 className="text-xl font-semibold">
            CEO 指令中心
          </h2>

          <p className="text-sm text-slate-400 mt-2">
            选择一位高管，准备向其发布工作指令。
          </p>

          <div className="flex flex-wrap gap-2 mt-5">
            {agents.map((agent) => (
              <button
                key={agent.code}
                onClick={() => setSelected(agent.code)}
                className={`px-3 py-2 rounded-lg text-xs ${
                  selected === agent.code
                    ? "bg-blue-600"
                    : "bg-slate-800 text-slate-300"
                }`}
              >
                {agent.code}
              </button>
            ))}
          </div>

          <textarea
            value={instruction}
            onChange={(e) => setInstruction(e.target.value)}
            placeholder={`给${selected || "AI高管"}输入工作指令...`}
            className="w-full mt-5 min-h-28 rounded-xl bg-[#0b1020] border border-slate-700 p-4 text-sm outline-none focus:border-blue-500"
          />

          <button
            disabled={!instruction.trim()}
            onClick={() =>
              alert(
                "目前尚未接入真实Agent对话系统，请等待下一阶段开发。"
              )
            }
            className="mt-4 bg-blue-600 hover:bg-blue-500 disabled:opacity-40 rounded-xl px-6 py-3 text-sm font-medium"
          >
            准备发送指令 →
          </button>

          <p className="text-xs text-slate-500 mt-4">
            当前已连接真实高管数据库，但Agent模型调用与消息发送功能尚未启用。
          </p>

        </div>

      </section>
    </main>
  );
}
