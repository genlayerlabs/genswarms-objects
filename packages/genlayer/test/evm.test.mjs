import {test} from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:net';
import {mkdtemp,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {randomBytes} from 'node:crypto';
import {createPublicClient,http,parseAbi} from 'viem';
import {GenLayerCore} from '../core.mjs';

test('real EVM native transfer and contract execution, receipt accounting and duplicate replay', {skip:!process.env.GENLAYER_EVM_TEST}, async t=>{
 const server=createServer();await new Promise(r=>server.listen(0,'127.0.0.1',r));const port=server.address().port;await new Promise(r=>server.close(r));
 const node=spawn('anvil',['--silent','--chain-id','4221','--port',String(port)],{stdio:'ignore'});
 t.after(()=>node.kill());
 const rpc=createPublicClient({transport:http(`http://127.0.0.1:${port}`,{retryCount:0})});
 for(let i=0;i<60;i++){try{await rpc.getChainId();break;}catch{await new Promise(r=>setTimeout(r,100));}}
 assert.equal(await rpc.getChainId(),4221);
 const root=await mkdtemp(join(tmpdir(),'genlayer-evm-'));t.after(()=>rm(root,{recursive:true,force:true}));
 await writeFile(join(root,'master'),randomBytes(32),{mode:0o600});
 const recipient='0x0000000000000000000000000000000000000123';
 const contract='0x0000000000000000000000000000000000000456';
 await rpc.request({method:'anvil_setCode',params:[contract,'0x60043560005500']}); // test-only setter: stores first ABI argument in slot 0
 const config={swarm_id:'evm',agents:['alice'],storage_dir:join(root,'vault'),master_key_file:join(root,'master'),rpc_url:`http://127.0.0.1:${port}`,write_enabled:true,confirmations:1,max_native_value:'1000',gas_reserve:'1000',max_gas_cost:'10000000000000000',recipes:{pay:{kind:'native',mode:'write',address:recipient,value:'10'},set:{mode:'write',address:contract,abi:parseAbi(['function set(uint256 value)']),function:'set',args:[{field:'value'}],fields:{value:{type:'uint',max:'100'}}}}};
 const core=await GenLayerCore.open(config);t.after(()=>core.close());
 const wallet=await core.provision('alice');await rpc.request({method:'anvil_setBalance',params:[wallet.address,'0xde0b6b3a7640000']});
 const p=await core.handle('alice',{action:'prepare',recipe:'pay',request_id:'pay'});
 const submitted=await core.handle('alice',{action:'submit',prepared_id:p.prepared_id});assert.equal(submitted.status,'broadcast');
 await rpc.waitForTransactionReceipt({hash:submitted.transaction_hash});
 assert.equal((await core.handle('alice',{action:'status',prepared_id:p.prepared_id})).status,'confirmed');
 assert.equal(await rpc.getBalance({address:recipient}),10n);
 assert.equal((await core.handle('alice',{action:'submit',prepared_id:p.prepared_id})).transaction_hash,submitted.transaction_hash);
 assert.equal(await rpc.getTransactionCount({address:wallet.address}),1);
 const q=await core.handle('alice',{action:'prepare',recipe:'set',args:{value:'42'},request_id:'set'});
 const sent=await core.handle('alice',{action:'submit',prepared_id:q.prepared_id});assert.equal(sent.status,'broadcast');
 await rpc.waitForTransactionReceipt({hash:sent.transaction_hash});assert.equal((await core.handle('alice',{action:'status',prepared_id:q.prepared_id})).status,'confirmed');
 assert.equal(BigInt(await rpc.getStorageAt({address:contract,slot:'0x0'})),42n);
 const balance=await core.handle('alice',{action:'balance'});assert.ok(BigInt(balance.balance_base_units)<10n**18n-10n);
});
