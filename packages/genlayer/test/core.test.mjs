import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,rm,readFile,cp,chmod} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {randomBytes} from 'node:crypto';
import {GenLayerCore} from '../core.mjs';
import {keccak256,parseTransaction,recoverTransactionAddress} from 'viem';

async function fixture(t, extra={}){
 const root=await mkdtemp(join(tmpdir(),'genlayer-object-'));t.after(()=>rm(root,{recursive:true,force:true}));
 const master=join(root,'master');await writeFile(master,randomBytes(32),{mode:0o600});
 const config={swarm_id:'test',agents:['alice','bob'],storage_dir:join(root,'vault'),master_key_file:master,write_enabled:true,max_native_value:'100',max_gas_cost:'100000000',gas_reserve:'10',recipes:{pay:{kind:'native',mode:'write',address:'0x0000000000000000000000000000000000000001',value:{field:'amount'},fields:{amount:{type:'uint',min:'1',max:'100'}}}},...extra};
 let broadcasts=0, receipt=null;
 const rpc={getChainId:async()=>4221,getBalance:async()=>1000000000n,call:async()=>({}),estimateGas:async()=>21000n,estimateFeesPerGas:async()=>({maxFeePerGas:2n,maxPriorityFeePerGas:1n}),getTransactionCount:async()=>0,sendRawTransaction:async({serializedTransaction})=>{broadcasts++;return keccak256(serializedTransaction);},getTransactionReceipt:async()=>{if(!receipt)throw Object.assign(Error('not found'),{name:'TransactionReceiptNotFoundError'});return receipt;},getBlock:async()=>({hash:'0xblock'}),getBlockNumber:async()=>10n};
 const core=await GenLayerCore.open(config,{rpc});t.after(()=>{try{core.close()}catch{}});
 return {core,config,rpc,root,broadcasts:()=>broadcasts,setReceipt:x=>receipt=x};
}
const prepare=(core,sender='alice',request='one')=>core.handle(sender,{action:'prepare',recipe:'pay',args:{amount:'5'},request_id:request});
test('discovery does not provision; caller identity, fields, writes and amounts fail closed',async t=>{
 const {core}=await fixture(t);
 assert.equal((await core.handle('alice',{action:'describe'})).wallet,null);
 await assert.rejects(core.handle('mallory',{action:'describe'}),/unauthorized_sender/);
 await core.provision('alice');
 await assert.rejects(core.handle('alice',{action:'balance',wallet:'bob'}),/invalid_request/);
 await assert.rejects(core.handle('alice',{action:'prepare',recipe:'pay',args:{amount:'1.2'},request_id:'x'}),/invalid_base_units/);
 await assert.rejects(core.handle('alice',{action:'prepare',recipe:'pay',args:{amount:'101'},request_id:'x'}),/amount_outside_limits/);
 core.config.write_enabled=false; await assert.rejects(prepare(core),/writes_disabled/);
});
test('prepared actions bind sender, expiry, policy and idempotent input',async t=>{
 const {core}=await fixture(t);await core.provision('alice');await core.provision('bob');
 const p=await prepare(core);assert.equal(p.status,'prepared');
 assert.equal((await prepare(core)).prepared_id,p.prepared_id);
 await assert.rejects(core.handle('bob',{action:'submit',prepared_id:p.prepared_id}),/unknown_prepared_action/);
 await assert.rejects(core.handle('alice',{action:'prepare',recipe:'pay',args:{amount:'6'},request_id:'one'}),/idempotency_conflict/);
 core.config.max_native_value='99';await assert.rejects(core.submit(core.identity('alice'),p.prepared_id),/policy_changed/);
 core.config.max_native_value='100';core.db.prepare('UPDATE proposals SET expires=0').run();await assert.rejects(core.submit(core.identity('alice'),p.prepared_id),/quote_expired/);
});
test('real signature, uncertain broadcast, restart and canonical receipt reconciliation',async t=>{
 const f=await fixture(t);const {core,rpc,config}=f;const wallet=await core.provision('alice');
 const p=await prepare(core);
 let sends=0;rpc.sendRawTransaction=async({serializedTransaction})=>{
   sends++;assert.equal(parseTransaction(serializedTransaction).chainId,4221);
   assert.equal(await recoverTransactionAddress({serializedTransaction}),wallet.address);throw Error('network timeout');
 };
 const result=await core.handle('alice',{action:'submit',prepared_id:p.prepared_id});assert.equal(result.status,'uncertain');
 core.close();const restored=await GenLayerCore.open(config,{rpc});t.after(()=>restored.close());
 assert.deepEqual(await restored.provision('alice'),wallet);
 assert.equal((await restored.handle('alice',{action:'submit',prepared_id:p.prepared_id})).status,'uncertain');assert.equal(sends,1);
 const second=await prepare(restored,'alice','two');await assert.rejects(restored.submit(restored.identity('alice'),second.prepared_id),/wallet_busy/);
 assert.equal((await restored.status(restored.identity('alice'),p.prepared_id)).status,'uncertain');
 f.setReceipt({transactionHash:result.transaction_hash,blockHash:'0xblock',blockNumber:10n,status:'success'});
 assert.equal((await restored.status(restored.identity('alice'),p.prepared_id)).status,'uncertain');
 rpc.getBlockNumber=async()=>11n;
 assert.equal((await restored.status(restored.identity('alice'),p.prepared_id)).status,'confirmed');
});
test('wrong chain and insufficient funds do not broadcast',async t=>{
 const {core,rpc,broadcasts}=await fixture(t);await core.provision('alice');
 const p=await prepare(core);rpc.getBalance=async()=>0n;
 assert.equal((await core.submit(core.identity('alice'),p.prepared_id)).status,'rejected');assert.equal(broadcasts(),0);
 rpc.getChainId=async()=>1;await assert.rejects(core.handle('alice',{action:'balance'}),/rpc_chain_mismatch/);
});
test('20 wallets persist, encrypted backup restores, swapped key files fail',async t=>{
 const agents=Array.from({length:20},(_,i)=>`agent${i}`);const {core,config,root}=await fixture(t,{agents});
 const wallets=await Promise.all(agents.map(a=>core.provision(a)));assert.equal(new Set(wallets.map(w=>w.address)).size,20);
 const key0=join(config.storage_dir,'keys',core.identity(agents[0])+'.json');
 const key1=join(config.storage_dir,'keys',core.identity(agents[1])+'.json');
 const encrypted=await readFile(key0);await writeFile(key1,encrypted);await assert.rejects(core.provision(agents[1]));
 await cp(config.storage_dir,join(root,'backup'),{recursive:true});await chmod(join(root,'backup'),0o700);
 const restored=await GenLayerCore.open({...config,storage_dir:join(root,'backup')},{rpc:core.rpc});t.after(()=>restored.close());
 assert.deepEqual(await restored.provision(agents[0]),wallets[0]);
});
