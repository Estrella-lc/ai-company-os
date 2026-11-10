
"use client";

import { use, useCallback, useEffect, useState } from "react";

type Agent = {
  id: string;
  code: string;
  name: string;
  title: string;
};

type Message = {
  id: string;
  sender_type: string;
  content: string;
  created_at: string;
};

export default function ChatPage({
  params,
}: {
  params: Promise<{ code: string }>;
}) {
  const { code: rawCode } = use(params);
  const code = rawCode.toUpperCase();

  const [agent, setAgent] = useState<Agent | null>(null);
  const [conversationId, setConversationId] = useState("");
  const [messages, setMessages] = useState<Message[]>([]);
  const [input, setInput] = useState("");
  const [loading, setLoading] = useState(true);
  const [sending, setSending] = useState(false);
  const [backgroundPending, setBackgroundPending] = useState(false);
  const [error, setError] = useState("");

  const loadChat = useCallback(async () => {
    try {
      setLoading(true);
      setError("");

      // Get or create this executive's conversation
      const conversationResponse = await fetch(
        `/api/agents/${encodeURIComponent(code)}`
      );

      const conversationData = await conversationResponse.json();

      if (!conversationResponse.ok || !conversationData.success) {
        throw new Error(
          conversationData.error || "无法打开高管会话"
        );
      }

      setAgent(conversationData.agent);
      setConversationId(conversationData.conversation.id);

      // Load persisted messages
      const messageResponse = await fetch(
        `/api/conversations/${conversationData.conversation.id}/messages`
      );

      const messageData = await messageResponse.json();

      if (!messageResponse.ok || !messageData.success) {
        throw new Error(
          messageData.error || "无法读取聊天记录"
        );
      }

      setMessages(messageData.messages || []);
    } catch (err) {
      setError(
        err instanceof Error ? err.message : "加载失败"
      );
    } finally {
      setLoading(false);
    }
  }, [code]);

  useEffect(() => {
    const timer = setTimeout(() => { void loadChat(); }, 0);
    return () => clearTimeout(timer);
  }, [loadChat]);



  useEffect(() => {
    if (!conversationId) return;
    let active = true;
    const poll = async () => {
      try {
        const response = await fetch('/api/conversations/' + encodeURIComponent(conversationId) + '/tasks', { cache: 'no-store' });
        if (!response.ok || !active) return;
        const result = await response.json();
        const pending = result.tasks.some((task: { execution_state: string }) => ['queued', 'running'].includes(task.execution_state));
        const history = await fetch('/api/conversations/' + encodeURIComponent(conversationId) + '/messages', { cache: 'no-store' });
        const messagesResult = await history.json();
        if (active && history.ok) setMessages(messagesResult.messages || []);
        if (active) setBackgroundPending(pending);
      } catch { /* A later poll can recover from a network interruption. */ }
    };
    void poll();
    const timer = setInterval(poll, 2500);
    return () => { active = false; clearInterval(timer); };
  }, [conversationId]);

async function sendMessage(e: React.FormEvent<HTMLFormElement>) {
  e.preventDefault();

  const content = input.trim();

  if (!content || !conversationId || sending) return;

  setSending(true);
  setError("");

  // Refresh history from the database
  async function refreshMessages() {
    const response = await fetch(
      `/api/conversations/${encodeURIComponent(conversationId)}/messages`,
      { cache: "no-store" }
    );

    const result = await response.json();

    if (!response.ok || !result.success) {
      throw new Error("无法读取最新聊天记录");
    }

    setMessages(result.messages || []);
    return result.messages || [];
  }

  try {
    // 1. Save the CEO message
    const response = await fetch(
      `/api/conversations/${encodeURIComponent(conversationId)}/messages`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ content }),
      }
    );

    const rawMessage = await response.text();

    let messageResult;

    try {
      messageResult = JSON.parse(rawMessage);
    } catch {
      throw new Error("CEO消息保存接口没有返回有效JSON");
    }

    if (!response.ok || !messageResult.success) {
      throw new Error(
        messageResult.error || "CEO消息保存失败"
      );
    }

    // Display the saved CEO message
    setMessages((previous) => [
      ...previous,
      messageResult.message,
    ]);

    setInput("");

    // Every active executive uses the durable reply queue.

        // Persist the job before waiting; this request does not run the model.
    const queued = await fetch('/api/conversations/' + encodeURIComponent(conversationId) + '/tasks', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ messageId: messageResult.message.id, requestKey: crypto.randomUUID() }),
    });
    const queuedResult = await queued.json();
    if (!queued.ok) throw new Error(queuedResult.error || 'Unable to queue reply');
    for (let attempt = 0; attempt < 120; attempt++) {
      await new Promise(resolve => setTimeout(resolve, 1500));
      const statusResponse = await fetch('/api/conversations/' + encodeURIComponent(conversationId) + '/tasks', { cache: 'no-store' });
      if (!statusResponse.ok) throw new Error('Unable to load task status');
      const statusResult = await statusResponse.json();
      const task = statusResult.tasks.find((item: { id: string }) => item.id === queuedResult.taskId);
      if (task?.execution_state === 'succeeded') { await refreshMessages(); return; }
      if (task?.execution_state === 'failed' || task?.execution_state === 'cancelled') {
        await refreshMessages(); throw new Error(code + '任务未完成：' + (task.last_error_code || task.execution_state));
      }
    }
    setError('任务仍在后台处理中，可刷新页面查看进度。');
} catch (err) {
    setError(
      err instanceof Error
        ? err.message
        : "消息处理失败"
    );

    // Recover messages already saved in Supabase
    try {
      await refreshMessages();
    } catch {
      // Preserve current visible messages.
    }

  } finally {
    setSending(false);
  }
}



  if (loading) {
    return (
      <main className="min-h-screen bg-[#0b1020] text-white flex items-center justify-center">
        正在加载聊天记录...
      </main>
    );
  }

  if (error && !agent) {
    return (
      <main className="min-h-screen bg-[#0b1020] text-white p-8">
        <p className="text-red-400">{error}</p>
        <button onClick={loadChat} className="mt-4 underline">
          重新加载
        </button>
      </main>
    );
  }

  return (
    <main className="min-h-screen bg-[#0b1020] text-slate-100 flex flex-col">

      <header className="border-b border-slate-800 p-5 flex items-center justify-between">
        <div>
          <p className="text-xs text-slate-500">
            AI COMPANY OS / PRIVATE CHAT
          </p>
          <h1 className="text-xl font-bold mt-1">
            {agent?.code} · {agent?.title}
          </h1>
          <p className="text-xs text-slate-400 mt-1">
            {agent?.name}
          </p>
        </div>


<span className="text-xs border rounded-full px-3 py-2 text-emerald-400 border-emerald-500/40">
  ● Gemini已接入 · {agent?.code}
</span>

      </header>

      <section className="flex-1 w-full max-w-4xl mx-auto p-5 overflow-y-auto">
        <div className="text-center text-xs text-slate-500 my-5">
          以下消息保存在你的Supabase数据库中
        </div>

        {messages.length === 0 && (
          <div className="text-center text-slate-500 mt-24">
            <div className="text-3xl mb-3">◈</div>
            <p>这是你与{agent?.title}的专属工作空间。</p>
            <p className="text-xs mt-2">
              发送第一条工作指令，开始记录对话。
            </p>
          </div>
        )}

        <div className="space-y-5">
          {messages.map((message) => (
            <div
              key={message.id}
              className={`flex ${
                message.sender_type === "user"
                  ? "justify-end"
                  : "justify-start"
              }`}
            >
              <div
                className={`max-w-[85%] rounded-2xl p-4 ${
                  message.sender_type === "user"
                    ? "bg-blue-600 text-white"
                    : "bg-[#1b2940] text-slate-100"
                }`}
              >
                <p className="text-xs opacity-70 mb-2">
                  {message.sender_type === "user"
                    ? "CEO"
                    : agent?.code}
                </p>

                <p className="text-sm whitespace-pre-wrap break-words">
                  {message.content}
                </p>

                <p className="text-[10px] opacity-60 mt-3">
                  {new Date(message.created_at).toLocaleString()}
                </p>
              </div>
            </div>
          ))}
        </div>
      </section>

      <footer className="border-t border-slate-800 p-5">
        <form
          onSubmit={sendMessage}
          className="max-w-4xl mx-auto flex gap-3"
        >
          <textarea
            value={input}
            onChange={(e) => setInput(e.target.value)}
            placeholder={`给${agent?.title}发送工作指令...`}
            rows={2}
            maxLength={10000}
            className="flex-1 resize-none bg-[#151e32] border border-slate-700 rounded-xl p-4 text-sm outline-none focus:border-blue-500"
          />

          <button
            type="submit"
            disabled={sending || !input.trim()}
            className="bg-blue-600 hover:bg-blue-500 disabled:opacity-40 rounded-xl px-5 py-3 text-sm"
          >
            {sending ? code + "思考中..." : "发送"}
          </button>
        </form>

        {error && (
          <p className="text-red-400 text-sm max-w-4xl mx-auto mt-3">
            {error}
          </p>
        )}

        <p className="text-xs text-slate-500 text-center mt-3">
          {backgroundPending ? code + "任务正在后台处理 · 刷新不会丢失任务" : code + "已接入Gemini · AI回复自动保存到Supabase"}
</p>
      </footer>
    </main>
  );
}
