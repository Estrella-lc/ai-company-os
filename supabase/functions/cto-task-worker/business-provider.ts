// Standard Gemini text API, same credentials/models; no additional tools or provider-side sessions.
import type {ThinkingLevel} from 'npm:@google/genai@2.32.0';
type Request={model:string;contents:string;config:{systemInstruction:string;maxOutputTokens:number;thinkingConfig:{thinkingLevel:ThinkingLevel};abortSignal:AbortSignal;httpOptions:{timeout:number;retryOptions:{attempts:number}};responseMimeType?:string;responseJsonSchema?:unknown}};
type Client={models:{generateContent:(request:Request)=>Promise<{text?:string;candidates?:{finishReason?:string}[];responseId?:string;usageMetadata?:{promptTokenCount?:number;candidatesTokenCount?:number}}>}};
export async function generateBusinessText(client:Client,p:{model:string;input:string;system:string;maxOutputTokens:number;schema?:unknown}){
 const r=await client.models.generateContent({model:p.model,contents:p.input,config:{systemInstruction:p.system,maxOutputTokens:p.maxOutputTokens,thinkingConfig:{thinkingLevel:'LOW' as ThinkingLevel},abortSignal:AbortSignal.timeout(45000),httpOptions:{timeout:45000,retryOptions:{attempts:1}},...(p.schema?{responseMimeType:'application/json',responseJsonSchema:p.schema}:{})}});
 if(r.candidates?.[0]?.finishReason!=='STOP'||!r.text?.trim())throw new Error('MODEL_OUTPUT_INCOMPLETE');
 return {status:'completed',output_text:r.text,id:r.responseId,usage:{total_input_tokens:r.usageMetadata?.promptTokenCount,total_output_tokens:r.usageMetadata?.candidatesTokenCount}};
}
