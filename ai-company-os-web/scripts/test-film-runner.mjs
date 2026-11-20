import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {checkedFilmUrl,verifyFilmBytes} from './film-runner.mjs';
const base='https://mcwkkmkgfienxrmfyvfl.supabase.co/storage/v1/object/';
test('grants restrict host, direction and bucket',()=>{
 assert.ok(checkedFilmUrl(base+'sign/company-creative/a/voice.wav?token=x'));
 assert.ok(checkedFilmUrl(base+'upload/sign/company-films/a/sample.mp4?token=x',true));
 for(const url of [base+'sign/company-films/a?token=x',base+'sign/company-creative/a',base.replace('https:','http:')+'sign/company-creative/a?token=x','https://evil.example/storage/v1/object/sign/company-creative/a?token=x'])assert.throws(()=>checkedFilmUrl(url));
 assert.throws(()=>checkedFilmUrl(base+'sign/company-creative/a?token=x',true));
});
test('input bytes must match the approved source hash and size',()=>{
 const bytes=Buffer.from('approved fixture'),hash=createHash('sha256').update(bytes).digest('hex');
 assert.equal(verifyFilmBytes(bytes,hash),bytes);
 assert.throws(()=>verifyFilmBytes(Buffer.from('changed'),hash));
 assert.throws(()=>verifyFilmBytes(bytes,hash,2));
 assert.throws(()=>verifyFilmBytes(bytes,''));
 assert.throws(()=>verifyFilmBytes(Buffer.alloc(0),hash));
});
