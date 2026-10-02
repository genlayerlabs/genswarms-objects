import { createInterface } from 'node:readline';
import { readFile } from 'node:fs/promises';
import { GenLayerCore } from './core.mjs';
let core;
const output = row=>{
  let encoded=JSON.stringify(row,(_,v)=>typeof v==='bigint'?v.toString():v);
  if(Buffer.byteLength(encoded)>60000)encoded=JSON.stringify({id:row.id,ok:false,error:{code:'response_too_large'}});
  process.stdout.write(encoded+'\n');
};
const safeError = e => ({code:/^[a-z_]+$/.test(e.code||'')?e.code:'operation_failed',retry_guidance:'Inspect status before retrying a submitted action; never generate a replacement request solely because of a timeout.'});
if(process.argv[2]==='provision'){
  try{
    core=await GenLayerCore.open(JSON.parse(await readFile(process.argv[3],'utf8')));
    const wallets=[];for(const sender of core.config.agents)wallets.push({agent:sender,...await core.provision(sender)});
    output({wallets});core.close();
  }catch(e){output({error:safeError(e)});process.exitCode=1;}
}else{
 const lines=createInterface({input:process.stdin,crlfDelay:Infinity});
 let initializing=false;
 for await(const line of lines){
  if(line.length>65536){output({error:{code:'request_too_large'}});continue;}
  let envelope;try{envelope=JSON.parse(line);}catch{output({error:{code:'invalid_json'}});continue;}
  if(!core){
    if(initializing||envelope.action!=='init'){output({error:{code:'not_initialized'}});continue;}
    initializing=true;
    try{core=await GenLayerCore.open(envelope.config);output({ready:true});}
    catch(e){output({error:safeError(e)});process.exitCode=1;lines.close();break;}
    continue;
  }
  Promise.resolve().then(()=>core.handle(envelope.sender,envelope.message))
   .then(result=>output({id:envelope.id,ok:true,result}))
   .catch(e=>output({id:envelope.id,ok:false,error:safeError(e)}));
 }
}
