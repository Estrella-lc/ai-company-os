
import { Suspense } from "react";
import ChatPage from "./chat-client";

export default function Page({
  params,
}: {
  params: Promise<{ code: string }>;
}) {
  return (
    <Suspense
      fallback={
        <main className="min-h-screen bg-[#0b1020] text-white flex items-center justify-center">
          正在加载AI高管聊天空间...
        </main>
      }
    >
      <ChatPage params={params} />
    </Suspense>
  );
}
