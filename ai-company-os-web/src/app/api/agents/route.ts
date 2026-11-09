
import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";

export async function GET() {
  try {
    const supabase = await createClient();

    // 1. Verify the CEO's authenticated identity
    const { data: authData, error: authError } =
      await supabase.auth.getClaims();

    if (authError || !authData?.claims) {
      return NextResponse.json(
        { error: "Unauthorized" },
        { status: 401 }
      );
    }

    // 2. Read agent records under the current user's RLS permissions
    const { data, error } = await supabase
      .from("agents")
      .select(
        "id, code, name, title, model_provider, model_name, is_active"
      )
      .order("code");

    if (error) {
      console.error("Agent query failed:", error.message);

      return NextResponse.json(
        { error: "Unable to retrieve agent records" },
        { status: 500 }
      );
    }

    // 3. Return verified database records
    return NextResponse.json(
      {
        success: true,
        count: data.length,
        agents: data,
      },
      {
        headers: {
          "Cache-Control": "private, no-store",
        },
      }
    );
  } catch (error) {
    console.error("Agents API error:", error);

    return NextResponse.json(
      { error: "Internal server error" },
      { status: 500 }
    );
  }
}
