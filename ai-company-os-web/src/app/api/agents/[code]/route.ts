
import { NextResponse, type NextRequest } from "next/server";
import { createClient } from "@/lib/supabase/server";

type RouteContext = {
  params: Promise<{ code: string }>;
};

export async function GET(
  request: NextRequest,
  context: RouteContext
) {
  try {
    const supabase = await createClient();

    // 1. Verify CEO identity
    const { data: authData, error: authError } =
      await supabase.auth.getClaims();

    if (authError || !authData?.claims?.sub) {
      return NextResponse.json(
        { error: "Unauthorized" },
        { status: 401 }
      );
    }

    const userId = authData.claims.sub;
    const { code } = await context.params;

    // 2. Find the requested executive
    const { data: agent, error: agentError } = await supabase
      .from("agents")
      .select("id, code, name, title, system_prompt, is_active")
      .eq("code", code.toUpperCase())
      .eq("is_active", true)
      .maybeSingle();

    if (agentError) {
      console.error("Agent lookup failed:", agentError.message);

      return NextResponse.json(
        { error: "Unable to find executive" },
        { status: 500 }
      );
    }

    if (!agent) {
      return NextResponse.json(
        { error: "Executive not found" },
        { status: 404 }
      );
    }

    // 3. Find the CEO's existing direct conversation
    const { data: existing, error: conversationError } =
      await supabase
        .from("conversations")
        .select("id, title, created_at")
        .eq("created_by", userId)
        .eq("agent_id", agent.id)
        .eq("conversation_type", "direct")
        .order("created_at", { ascending: false })
        .limit(1)
        .maybeSingle();

    if (conversationError) {
      console.error(
        "Conversation lookup failed:",
        conversationError.message
      );

      return NextResponse.json(
        { error: "Unable to retrieve conversation" },
        { status: 500 }
      );
    }

    // 4. Reuse the existing conversation
    if (existing) {
      return NextResponse.json({
        success: true,
        created: false,
        agent,
        conversation: existing,
      });
    }

    // 5. Create a new private conversation
    const { data: conversation, error: createError } =
      await supabase
        .from("conversations")
        .insert({
          project_id: null,
          agent_id: agent.id,
          conversation_type: "direct",
          title: `${agent.code} - CEO Private Chat`,
          created_by: userId,
        })
        .select("id, title, created_at")
        .single();

    if (createError) {
      console.error("Conversation creation failed:", createError.message);

      return NextResponse.json(
        { error: "Unable to create conversation" },
        { status: 500 }
      );
    }

    return NextResponse.json({
      success: true,
      created: true,
      agent,
      conversation,
    });
  } catch (error) {
    console.error("Conversation API error:", error);

    return NextResponse.json(
      { error: "Internal server error" },
      { status: 500 }
    );
  }
}
