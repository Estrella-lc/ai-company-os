
import { NextResponse, type NextRequest } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { generateGeminiResponse } from "@/lib/ai/gemini";

type RouteContext = {
  params: Promise<{ id: string }>;
};

export async function POST(
  request: NextRequest,
  context: RouteContext
) {
  try {
    // 1. Verify CEO identity
    const supabase = await createClient();

    const { data: authData, error: authError } =
      await supabase.auth.getClaims();

    if (authError || !authData?.claims?.sub) {
      return NextResponse.json(
        { error: "Unauthorized" },
        { status: 401 }
      );
    }

    const userId = authData.claims.sub;
    const { id: conversationId } = await context.params;

    // 2. Verify conversation ownership
    const { data: conversation, error: conversationError } =
      await supabase
        .from("conversations")
        .select("id, agent_id, created_by")
        .eq("id", conversationId)
        .eq("created_by", userId)
        .maybeSingle();

    if (conversationError || !conversation) {
      return NextResponse.json(
        { error: "Conversation not found or access denied" },
        { status: 404 }
      );
    }

    // 3. Load the executive profile
    const { data: agent, error: agentError } =
      await supabase
        .from("agents")
        .select("id, code, name, title, system_prompt, is_active")
        .eq("id", conversation.agent_id)
        .maybeSingle();

    if (agentError || !agent || !agent.is_active) {
      return NextResponse.json(
        { error: "Executive profile unavailable" },
        { status: 404 }
      );
    }

    // Initial release: CTO only
    if (agent.code !== "CTO") {
      return NextResponse.json(
        { error: "AI reply is currently enabled for CTO only" },
        { status: 403 }
      );
    }

    // 4. Validate the triggering CEO message
    const body = await request.json();

    if (
      typeof body.messageId !== "string" ||
      body.messageId.length > 100
    ) {
      return NextResponse.json(
        { error: "Valid messageId is required" },
        { status: 400 }
      );
    }

    const { data: triggerMessage, error: triggerError } =
      await supabase
        .from("messages")
        .select("id, sender_type, content, created_at")
        .eq("id", body.messageId)
        .eq("conversation_id", conversationId)
        .eq("sender_type", "user")
        .maybeSingle();

    if (triggerError || !triggerMessage) {
      return NextResponse.json(
        { error: "CEO message not found" },
        { status: 404 }
      );
    }

    // 5. Check whether this message already has a reply
    const admin = createAdminClient();

    const { data: existingReplies, error: duplicateError } =
      await admin
        .from("messages")
        .select("id")
        .eq("conversation_id", conversationId)
        .eq("sender_type", "assistant")
        .eq("sender_agent_id", agent.id)
        .gt("created_at", triggerMessage.created_at)
        .limit(1);

    if (duplicateError) {
      console.error("Duplicate check failed:", duplicateError.message);

      return NextResponse.json(
        { error: "Unable to verify reply status" },
        { status: 500 }
      );
    }

    if (existingReplies?.length) {
      return NextResponse.json(
        { error: "A reply already exists after this message" },
        { status: 409 }
      );
    }

    // 6. Load the most recent conversation history
    const { data: history, error: historyError } =
      await supabase
        .from("messages")
        .select("sender_type, content")
        .eq("conversation_id", conversationId)
        .order("created_at", { ascending: false })
        .limit(20);

    if (historyError || !history) {
      return NextResponse.json(
        { error: "Unable to load conversation history" },
        { status: 500 }
      );
    }

    const transcript = history
      .reverse()
      .map((item) => {
        const speaker =
          item.sender_type === "user" ? "CEO" : "CTO";

        return `${speaker}: ${item.content}`;
      })
      .join("\n\n");

    // 7. Build CTO professional instructions
    const systemInstruction = `
You are the Chief Technology Officer (CTO) of AI Company OS.

Your professional responsibilities:
1. Technology strategy and architecture.
2. AI model integration.
3. Multi-agent system architecture.
4. Database and information security.
5. Engineering quality and deployment.
6. Technical cost optimization.

Your working rules:
- Communicate directly with the CEO.
- Think like an experienced technology executive.
- Explain technical concepts clearly.
- Separate facts, assumptions and estimates.
- Identify technical risks before recommending actions.
- Give concrete and executable next steps.
- Never claim that an operation has been completed unless verified.
- Never invent company data or system capabilities.
- Respond in the same language as the CEO.

Specific CTO profile:
${agent.system_prompt || "No additional CTO instructions configured."}
    `.trim();

    // 8. Generate a real Gemini response
    console.info("CTO_REPLY_GENERATING", { conversationId });
    const answer = await generateGeminiResponse({
      systemInstruction,
      message: transcript,
    });

    if (!answer || !answer.trim()) {
      throw new Error("Gemini returned an empty response");
    }

    console.info("CTO_REPLY_GENERATED", { conversationId, characters: answer.length });
    // 9. Save the AI reply using the server-only admin client
    const { data: savedMessage, error: saveError } =
      await admin
        .from("messages")
        .insert({
          conversation_id: conversationId,
          sender_type: "assistant",
          sender_agent_id: agent.id,
          content: answer.trim(),
        })
        .select(
          "id, sender_type, sender_agent_id, content, created_at"
        )
        .single();

    if (saveError) {
      console.error("AI reply save failed:", saveError.message);

      return NextResponse.json(
        { error: "AI generated a response but saving failed" },
        { status: 500 }
      );
    }

    return NextResponse.json({
      success: true,
      agent: {
        code: agent.code,
        title: agent.title,
      },
      message: savedMessage,
    });

  } catch (error) {
    console.error("CTO_REPLY_FAILED", { name: error instanceof Error ? error.name : "UnknownError" });

    return NextResponse.json(
      { error: "CTO 模型暂时不可用或响应超时。你的消息已保存，请稍后再试。" },
      { status: 500 }
    );
  }
}
