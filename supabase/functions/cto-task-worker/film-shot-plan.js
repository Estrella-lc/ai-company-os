// Data-only contract for platform employee shot plans. Never execute model commands.
export function validateShotPlan(plan, approvedAssets) {
 if (!plan || !Array.isArray(plan.shots) || plan.shots.length < 2 || plan.shots.length > 6) throw Error('SHOT_COUNT');
 const assets = new Map(approvedAssets.map(a => [a.id, a]));
 let cursor = 0;
 const ids = new Set();
 for (const shot of plan.shots) {
  if (!shot || typeof shot.id !== 'string' || !/^[a-z0-9_-]{1,40}$/.test(shot.id) || ids.has(shot.id)) throw Error('SHOT_ID');
  ids.add(shot.id);
  if (!Number.isFinite(shot.start) || !Number.isFinite(shot.duration) || Math.abs(shot.start-cursor) > .001 || shot.duration < 1 || shot.duration > 12) throw Error('SHOT_TIMELINE');
  cursor += shot.duration;
  if (!['still','slow_push','slow_pull'].includes(shot.motion)) throw Error('UNSUPPORTED_MOTION');
  const image = assets.get(shot.image);
  if (!image || image.kind !== 'image' || image.verdict !== 'pass' || !/^[a-f0-9]{64}$/.test(image.sha256 || '')) throw Error('UNAPPROVED_IMAGE');
  if (shot.voice != null) {
   const voice = assets.get(shot.voice);
   if (!voice || voice.kind !== 'voice' || voice.verdict !== 'pass' || !/^[a-f0-9]{64}$/.test(voice.sha256 || '')) throw Error('UNAPPROVED_VOICE');
   if (!Number.isFinite(voice.duration) || voice.duration <= 0 || voice.duration > shot.duration || shot.dialogue !== voice.transcript) throw Error('VOICE_FIDELITY_OR_TRUNCATION');
  } else if (shot.dialogue) throw Error('MISSING_VOICE');
 }
 if (cursor < 15 || cursor > 30) throw Error('FILM_DURATION');
 return {duration:cursor,shots:plan.shots.length,scope:'still_image_edit',requiresIndependentFilmReview:true};
}

export function nextFilmStep({ceoAccepted,storyboardApproved,assetsReady,rendered,independentPassed}) {
 if (!ceoAccepted) return 'await_ceo_sample_acceptance';
 if (!storyboardApproved) return 'employee_storyboard_and_capability_gap_review';
 if (!assetsReady) return 'research_validate_and_prepare_missing_assets';
 if (!rendered) return 'isolated_ffmpeg_edit';
 if (!independentPassed) return 'independent_film_inspection';
 return 'await_ceo_film_acceptance';
}
