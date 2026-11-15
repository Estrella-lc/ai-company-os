export const documentByteLimit=2*1024*1024;
export async function readDocumentUpload(body:ReadableStream<Uint8Array>|null){
 if(!body)throw new Error('empty_document');
 const reader=body.getReader(),chunks:Uint8Array[]=[];let size=0;
 try{while(true){const {done,value}=await reader.read();if(done)break;size+=value.byteLength;if(size>documentByteLimit){await reader.cancel();throw new Error('document_too_large');}chunks.push(value);}}
 finally{reader.releaseLock();}
 if(!size)throw new Error('empty_document');
 const bytes=new Uint8Array(size);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}return bytes;
}

