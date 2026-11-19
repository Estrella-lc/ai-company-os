type Health={model_name:string;call_status:string;error_kind?:string|null};
// Caller supplies only this owner's recent rows. Keep both configured models and the same call cap.
export function businessModelOrder(models:string[],recent:Health[]){
 const unique=[...new Set(models)];if(unique.length!==2)return unique;
 const primary=recent.filter(r=>r.model_name===unique[0]).slice(0,2);
 const fallback=recent.find(r=>r.model_name===unique[1]);
 return primary.length===2&&primary.every(r=>r.call_status==='failed'&&['provider_unavailable','timeout'].includes(r.error_kind||''))&&fallback?.call_status==='completed'?[unique[1],unique[0]]:unique;
}
