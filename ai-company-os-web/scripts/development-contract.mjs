export const contract=`Implement one Python module exposing analyze_srt(text: str, duration_seconds=None) -> dict.
Return {"valid": bool, "cue_count": int, "issues": [{"code": str, "cue": int}]}.
Allowed codes: EMPTY_INPUT, FORMAT_ERROR, EMPTY_TEXT, INVALID_TIME, OVERLAP, OUT_OF_RANGE, TEXT_TOO_LONG.
Normalize UTF-8 BOM and CRLF/CR. Empty/whitespace input: cue_count=0 and EMPTY_INPUT.
Split nonempty SRT blocks on blank lines; cue_count is number of blocks, including invalid blocks.
Each block begins with a digits-only index and then HH:MM:SS,mmm --> HH:MM:SS,mmm; minutes/seconds 0..59. Bad index or bad timestamp syntax -> FORMAT_ERROR. A block lacking text -> EMPTY_TEXT (not FORMAT_ERROR if index and timestamp exist).
End must exceed start, otherwise INVALID_TIME. Check overlap with the preceding valid interval: current start < previous end -> OVERLAP; adjacency is allowed.
If duration_seconds is supplied and positive, valid intervals ending later than it -> OUT_OF_RANGE.
At least one nonblank text line is required. More than 2 nonblank lines, or a text line over 42 Unicode characters -> TEXT_TOO_LONG.
issues may contain multiple codes. cue uses the 1-based block position, not the written SRT index. EMPTY_INPUT uses cue=0. valid is true exactly when issues is empty.
Only Python standard library imports re/json/math/typing/unicodedata are allowed. No files/network/processes, no dunder attributes, dynamic evaluation or global/nonlocal statements. No dependencies. The immutable acceptance tests cannot be changed.
Respond with just a JSON object {"source": "complete Python module"}. No markdown fences or explanations.`;
export function acceptanceCases(){
 const cue=(a,b,text='Hello',index=1)=>`${index}\n${a} --> ${b}\n${text}`;
 const one=cue('00:00:00,000','00:00:01,000');
 const rows=[
  ['basic',one,2,1,[]],['empty','',2,0,['EMPTY_INPUT']],['whitespace',' \n\t ',2,0,['EMPTY_INPUT']],
  ['bom_crlf','\ufeff'+one.replaceAll('\n','\r\n'),2,1,[]],['chinese',cue('00:00:00,000','00:00:01,000','你好，AI公司'),2,1,[]],
  ['no_text',cue('00:00:00,000','00:00:01,000',''),2,1,['EMPTY_TEXT']],['bad_index',one.replace(/^1/,'x'),2,1,['FORMAT_ERROR']],
  ['bad_syntax',one.replace(',000 -->', '.000 -->'),2,1,['FORMAT_ERROR']],['bad_minute',cue('00:61:00,000','00:61:01,000'),null,1,['FORMAT_ERROR']],
  ['reverse',cue('00:00:02,000','00:00:01,000'),3,1,['INVALID_TIME']],['zero',cue('00:00:01,000','00:00:01,000'),3,1,['INVALID_TIME']],
  ['overlap',one+'\n\n'+cue('00:00:00,500','00:00:02,000','Second',2),3,2,['OVERLAP']],
  ['adjacent',one+'\n\n'+cue('00:00:01,000','00:00:02,000','Second',2),3,2,[]],
  ['out_of_range',one,0.5,1,['OUT_OF_RANGE']],['no_duration',one,null,1,[]],['long_line',cue('00:00:00,000','00:00:01,000','字'.repeat(43)),2,1,['TEXT_TOO_LONG']],
  ['many_lines',cue('00:00:00,000','00:00:01,000','a\nb\nc'),2,1,['TEXT_TOO_LONG']],['boundary',cue('00:00:00,000','00:00:01,000','a'.repeat(42)),2,1,[]],
 ];
 for(let i=0;i<8;i++){const offset=2+Math.floor(Math.random()*40),stamp=n=>`00:00:${String(n).padStart(2,'0')},000`;rows.push(['generated_'+i,cue(stamp(offset),stamp(offset+1),'case '+i),offset+2,1,[]]);}
 return rows.map(([name,text,duration,count,codes])=>({name,input:{text,duration_seconds:duration},expected:{count,codes}}));
}
export function checkAnswer(answer,expected){
 const r=answer?.result;
 if(!r || typeof r.valid!=='boolean' || !Number.isInteger(r.cue_count) || !Array.isArray(r.issues))return 'Invalid output schema';
 if(r.issues.some(i=>!i || typeof i.code!=='string' || !Number.isInteger(i.cue)))return 'Invalid issue schema';
 const codes=[...new Set(r.issues.map(i=>i.code))].sort(),want=[...expected.codes].sort();
 if(r.cue_count!==expected.count || r.valid!==(want.length===0) || JSON.stringify(codes)!==JSON.stringify(want))return JSON.stringify({expected:{cue_count:expected.count,codes:want,valid:want.length===0},actual:{cue_count:r.cue_count,codes,valid:r.valid}});
 return null;
}
