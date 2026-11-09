
"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

export default function LoginPage() {
  const router = useRouter();

  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");

  async function handleLogin(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setLoading(true);
    setError("");

    try {
      const supabase = createClient();

      const { error } = await supabase.auth.signInWithPassword({
        email,
        password,
      });

      if (error) {
        setError("登录失败，请检查邮箱和密码。");
        return;
      }

      router.replace("/");
      router.refresh();
    } catch {
      setError("系统连接失败，请检查Supabase配置。");
    } finally {
      setLoading(false);
    }
  }

  return (
    <main className="min-h-screen bg-[#0b1020] flex items-center justify-center p-5 text-white">
      <div className="w-full max-w-md">
        <div className="text-center mb-9">
          <div className="text-4xl mb-4">◈</div>
          <h1 className="text-3xl font-bold tracking-wide">
            AI COMPANY OS
          </h1>
          <p className="text-slate-400 text-sm mt-3">
            Virtual Enterprise Operating System
          </p>
          <p className="text-blue-400 text-xs mt-2">
            CEO CONTROL CENTER
          </p>
        </div>

        <form
          onSubmit={handleLogin}
          className="bg-[#151e32] border border-slate-700 rounded-2xl p-7 shadow-xl"
        >
          <h2 className="text-xl font-semibold mb-2">
            CEO 登录
          </h2>

          <p className="text-sm text-slate-400 mb-7">
            请使用你的公司管理员账户登录。
          </p>

          <label className="block text-sm mb-2">
            CEO 邮箱
          </label>

          <input
            type="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            required
            autoComplete="username"
            placeholder="请输入注册邮箱"
            className="w-full bg-[#0b1020] border border-slate-700 rounded-xl px-4 py-3 mb-5 outline-none focus:border-blue-500"
          />

          <label className="block text-sm mb-2">
            登录密码
          </label>

          <input
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            required
            autoComplete="current-password"
            placeholder="请输入密码"
            className="w-full bg-[#0b1020] border border-slate-700 rounded-xl px-4 py-3 outline-none focus:border-blue-500"
          />

          {error && (
            <p className="text-red-400 text-sm mt-4">
              {error}
            </p>
          )}

          <button
            type="submit"
            disabled={loading}
            className="w-full mt-7 bg-blue-600 hover:bg-blue-500 disabled:opacity-50 rounded-xl py-3 font-medium transition"
          >
            {loading ? "正在验证..." : "登录 CEO 控制台 →"}
          </button>

          <p className="text-center text-xs text-slate-500 mt-6">
            AI Company OS · Private Workspace
          </p>
        </form>
      </div>
    </main>
  );
}
