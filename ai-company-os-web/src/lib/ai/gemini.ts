import "server-only";
import { GoogleGenAI } from "@google/genai";
let geminiClient: GoogleGenAI | null = null;
function getGeminiClient() {
  const apiKey = process.env.GEMINI_API_KEY;
  if (!apiKey) throw new Error("GEMINI_API_KEY is not configured");
  return geminiClient ??= new GoogleGenAI({ apiKey });
}
function isTransient(error: unknown) {
  const e = error as { status?: number; statusCode?: number; name?: string; message?: string };
  const status = e.status ?? e.statusCode;
  return [408, 429, 500, 502, 503, 504].includes(status ?? 0) || /timeout|timed out|deadline|high demand|overloaded|temporarily unavailable|503|429/i.test(e.message ?? "") || /timeout/i.test(e.name ?? "");
}
export async function generateGeminiResponse({ systemInstruction, message }: { systemInstruction: string; message: string }): Promise<string> {
  const ai = getGeminiClient();
  const primary = process.env.GEMINI_MODEL || "gemini-3.8-flash";
  const fallback = process.env.GEMINI_FALLBACK_MODEL || "gemini-3.5-flash-lite";
  const models = [...new Set([primary, fallback].filter(Boolean))];
  for (let index = 0; index < models.length; index++) {
    const model = models[index];
    const started = Date.now();
    try {
      const interaction = await ai.interactions.create({
        model, input: message, system_instruction: systemInstruction,
        generation_config: { max_output_tokens: 2400, thinking_level: "low" },
      }, { timeout_ms: index === 0 && models.length > 1 ? 15000 : 30000, maxRetries: 0 });
      const answer = interaction.output_text;
      if (interaction.status !== "completed" || !answer?.trim()) throw new Error("Gemini returned an incomplete or empty response");
      console.info("CTO_MODEL_COMPLETED", { model, fallback: index > 0, durationMs: Date.now() - started });
      return answer.trim();
    } catch (error) {
      const retry = index + 1 < models.length && isTransient(error);
      console.warn("CTO_MODEL_FAILED", { model, durationMs: Date.now() - started, fallbackNext: retry });
      if (!retry) throw error;
    }
  }
  throw new Error("No Gemini model available");
}
