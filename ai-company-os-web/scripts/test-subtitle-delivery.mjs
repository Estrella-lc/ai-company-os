import assert from 'node:assert/strict';
import {checkedMediaUrl} from './subtitle-delivery.mjs';
const base='https://mcwkkmkgfienxrmfyvfl.supabase.co/storage/v1/object/';
assert.ok(checkedMediaUrl(base+'sign/company-media/a/b/input.mp4?token=x'));
assert.ok(checkedMediaUrl(base+'upload/sign/company-media/a/b/out.mp4?token=x',true));
for(const url of ['http://mcwkkmkgfienxrmfyvfl.supabase.co/storage/v1/object/sign/company-media/a?token=x','https://evil.example/file?token=x',base+'sign/other/a?token=x',base+'sign/company-media/a',base+'sign/company-media/../other/a?token=x'])assert.throws(()=>checkedMediaUrl(url));
assert.throws(()=>checkedMediaUrl(base+'sign/company-media/a?token=x',true));
console.log('PASS: media URLs restricted to private storage, intended operation, TLS and signed capabilities');
