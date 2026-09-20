// Operator-only command; never expose it as an agent tool.
import {readFile,open,mkdir} from 'node:fs/promises';
import {dirname} from 'node:path';
import {randomBytes} from 'node:crypto';
import {spawnSync} from 'node:child_process';
const configPath=process.argv[2];
if(!configPath)throw Error('Usage: node scripts/setup.mjs /absolute/path/operator-config.json');
const config=JSON.parse(await readFile(configPath,'utf8'));
await mkdir(dirname(config.master_key_file),{recursive:true,mode:0o700});
try{
 const f=await open(config.master_key_file,'wx',0o600);
 try{await f.writeFile(randomBytes(32));await f.sync();}finally{await f.close();}
}catch(e){if(e.code!=='EEXIST')throw e;}
const result=spawnSync(process.execPath,[new URL('../runtime.mjs',import.meta.url).pathname,'provision',configPath],{stdio:'inherit'});
process.exitCode=result.status??1;
