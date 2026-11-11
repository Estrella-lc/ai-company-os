export const developmentContract=`Implement one Python module exposing analyze_srt(text: str, duration_seconds=None) -> dict.
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
