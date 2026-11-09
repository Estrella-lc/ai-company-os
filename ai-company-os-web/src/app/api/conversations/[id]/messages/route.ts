
import { NextResponse, type NextRequest } from "next/server";
import { createClient } from "@/lib/supabase/server";

type RouteContext = {
  params: Promise<{ id: string }>;
};

// Read conversation history
export async function GET(
  request: NextRequest,
  context: RouteContext
) {
  try {
    const supabase = await createClient();

    const { data: authData, error: authError } =
      await supabase.auth.getClaims();

    if (authError || !authData?.claims?.sub) {
      return NextResponse.json(
        { error: "Unauthorized" },
        { status: 401 }
      );
    }

    const { id } = await context.params;

    const { data, error } = await supabase
      .from("messages")
      .select("id, sender_type, sender_agent_id, content, created_at")
      .eq("conversation_id", id)
      .order("created_at", { ascending: true });

    if (error) {
      console.error("Message history error:", error.message);

      return NextResponse.json(
        { error: "Unable to retrieve messages" },
        { status: 500 }
      );
    }

    return NextResponse.json({
      success: true,
      count: data.length,
      messages: data,
    });
  } catch (error) {
    console.error("Message GET error:", error);

    return NextResponse.json(
      { error: "Internal server error" },
      { status: 500 }
    );
  }
}

// Save a CEO message
export async function POST(
  request: NextRequest,
  context: RouteContext
) {
  try {
    const supabase = await createClient();

    const { data: authData, error: authError } =
      await supabase.auth.getClaims();

    if (authError || !authData?.claims?.sub) {
      return NextResponse.json(
        { error: "Unauthorized" },
        { status: 401 }
      );
    }

    const { id } = await context.params;
    const body = await request.json();

    if (
      typeof body.content !== "string" ||
      !body.content.trim() ||
      body.content.length > 10000
    ) {
      return NextResponse.json(
        { error: "Message must contain 1-10000 characters" },
        { status: 400 }
      );
    }

    const { data, error } = await supabase
      .from("messages")
      .insert({
        conversation_id: id,
        sender_type: "user",
        sender_agent_id: null,
        content: body.content.trim(),
      })
      .select("id, sender_type, content, created_at")
      .single();

    if (error) {
      console.error("Message insert error:", error.message);

      return NextResponse.json(
        { error: "Unable to save message" },
        { status: 500 }
      );
    }

    return NextResponse.json({
      success: true,
      message: data,
    });
  } catch (error) {
    console.error("Message POST error:", error);

    return NextResponse.json(
      { error: "Internal server error" },
      { status: 500 }
    );
  }
}
