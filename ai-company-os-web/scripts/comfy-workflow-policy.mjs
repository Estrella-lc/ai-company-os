import {createHash} from 'node:crypto';
// Static inspection only. Even native nodes execute code on the target server.
export function inspectComfyWorkflow(workflow,installedClasses=[]){
 if(!workflow||typeof workflow!=='object'||Array.isArray(workflow)||Object.keys(workflow).length>200)throw Error('Invalid API workflow');
 const entries=Object.entries(workflow);if(!entries.length)throw Error('Empty workflow');
 const classes=[];const modelFiles=[];
 for(const [id,node] of entries){
  if(!/^\d+$/.test(id)||typeof node?.class_type!=='string'||!node.inputs||typeof node.inputs!=='object'||Array.isArray(node.inputs))throw Error('API-format workflow required');
  classes.push(node.class_type);
  for(const [key,value] of Object.entries(node.inputs)){
   if(typeof value==='string'&&/https?:|file:|\.\.[/\\]|^[A-Za-z]:[/\\]/i.test(value))throw Error('External path or URL requires review');
   if(/(?:ckpt|model|vae|clip|lora).*name$/i.test(key)&&typeof value==='string')modelFiles.push(value);
   if(Array.isArray(value)&&value.length===2&&typeof value[0]==='string'&&!workflow[value[0]])throw Error('Broken node link');
  }
 }
 const hasImage=classes.includes('LoadImage'),hasVideo=classes.some(x=>/Wan.*ImageToVideo|LTXV.*(?:ImgToVideo|ImageToVideo)/i.test(x));
 const missing=[...new Set(classes.filter(c=>!installedClasses.includes(c)))];
 return {workflow_sha256:createHash('sha256').update(JSON.stringify(workflow)).digest('hex'),classes:[...new Set(classes)],model_files:[...new Set(modelFiles)],image_conditioned:hasImage&&hasVideo,missing_nodes:missing,static_passed:hasImage&&hasVideo&&missing.length===0,runtime_verified:false,character_quality_verified:false,third_party_scripts_executed:false};
}

