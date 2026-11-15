import assert from 'node:assert/strict';
import {readDocumentUpload,documentByteLimit} from '../src/lib/document-upload.ts';
const stream=(chunks)=>new ReadableStream({start(controller){for(const chunk of chunks)controller.enqueue(chunk);controller.close();}});
assert.deepEqual(await readDocumentUpload(stream([new Uint8Array([1,2]),new Uint8Array([3])])),new Uint8Array([1,2,3]));
assert.equal((await readDocumentUpload(stream([new Uint8Array(documentByteLimit)]))).length,documentByteLimit);
await assert.rejects(()=>readDocumentUpload(null),/empty_document/);
await assert.rejects(()=>readDocumentUpload(stream([])),/empty_document/);
await assert.rejects(()=>readDocumentUpload(stream([new Uint8Array(documentByteLimit),new Uint8Array([1])])),/document_too_large/);
console.log('PASS: document streaming upload boundary, chunk integrity and empty/oversize refusal');

