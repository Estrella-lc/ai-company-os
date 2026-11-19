// Error messages can contain URLs or credentials. Never persist or log them.
export function providerFailure(error:unknown){
 const e=error&&typeof error==='object'?error as {status?:unknown;message?:unknown;name?:unknown}:{};
 const status=typeof e.status==='number'&&Number.isInteger(e.status)&&e.status>=100&&e.status<=599?e.status:null;
 const message=typeof e.message==='string'?e.message:String(error);
 const kind=/API_KEY_INVALID|API key not valid|api key.*(?:expired|leaked|invalid)|invalid.*api.key/i.test(message)?'credentials':status===401||status===403?'permission':status===429||/quota|rate.limit|RESOURCE_EXHAUSTED/i.test(message)?'rate_limit':status===404?'model_unavailable':/timeout|timed out|deadline|TimeoutError/i.test(message+' '+e.name)?'timeout':status!==null&&status>=500?'provider_unavailable':status===400?'invalid_request':/fetch failed|network|connection/i.test(message)?'network':/MODEL_OUTPUT_INCOMPLETE|EMPTY_RESPONSE/i.test(message)?'incomplete':'unknown';
 return {error_kind:kind,http_status:status};
}
