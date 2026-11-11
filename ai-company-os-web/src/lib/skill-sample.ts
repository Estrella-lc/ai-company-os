// A synthetic adapter output is a demo delivery, never proof the whole skill ran.
export function skillSample(result: unknown) {
 if (!result || typeof result !== 'object') return null;
 const r=result as Record<string,unknown>;
 if(typeof r.run_url!=='string' || !/^https:\/\/github\.com\/Estrella-lc\/ai-company-os\/actions\/runs\/[0-9]+$/.test(r.run_url) || !Array.isArray(r.candidates))return null;
 const candidate=r.candidates.find(c=>c?.verification?.passed===true && c.verification.scope==='subtitle_fixture_v1' && /^[0-9a-f]{64}$/.test(c.verification.output_sha256 || ''));
 if(!candidate)return null;
 const v=candidate.verification;
 const review=r.sample_review && typeof r.sample_review==='object'?r.sample_review as Record<string,unknown>:null;
 return {scope:'subtitle_fixture_v1',runUrl:r.run_url,sha256:v.output_sha256 as string,duration:typeof v.duration==='number'?v.duration:null,cues:typeof v.subtitle_cues==='number'?v.subtitle_cues:null,files:['sandbox/subtitled.mp4','sandbox/input.mp4','sandbox/sample.srt','sandbox/verification.json'],review:review?{state:String(review.state),note:String(review.note || ''),reviewedAt:String(review.reviewed_at || '')}:null};
}
