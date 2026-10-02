import { DatabaseSync } from 'node:sqlite';
import { mkdir, readFile, chmod, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { createHash, randomBytes } from 'node:crypto';
import { createPublicClient, http, encodeFunctionData, decodeFunctionResult, isAddress, keccak256 } from 'viem';
import { createClient as createGenLayerClient } from 'genlayer-js';
import { testnetBradbury } from 'genlayer-js/chains';
import { Vault } from './vault.mjs';
import schema from './schema.json' with { type: 'json' };

const canonical = value => JSON.stringify(value, (_,v)=> typeof v === 'bigint' ? v.toString() : v);
const digest = value => createHash('sha256').update(canonical(value)).digest('hex');
const fail = code => { throw Object.assign(new Error(code), {code}); };
const integer = value => {
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]{0,77})$/.test(value)) fail('invalid_base_units');
  return BigInt(value);
};
const id = value => typeof value === 'string' && /^[\w-]{1,128}$/.test(value);
export class GenLayerCore {
  constructor(config, db, vault, rpc, gen) { Object.assign(this,{config,db,vault,rpc,gen}); }
  static async open(config, overrides={}) {
    if (!config.swarm_id || !Array.isArray(config.agents) || !config.agents.every(id)) fail('invalid_identity_config');
    if (config.chain_id !== undefined && config.chain_id !== 4221 && !overrides.rpc) fail('unsupported_chain');
    config={chain_id:4221,rpc_url:'https://rpc-bradbury.genlayer.com',confirmations:2,ttl_seconds:60,write_enabled:false,recipes:{},...config};
    if (!Number.isInteger(config.confirmations) || config.confirmations<1 || !Number.isInteger(config.ttl_seconds) || config.ttl_seconds<1 || config.ttl_seconds>300) fail('invalid_config');
    if (!config.storage_dir || !config.master_key_file) fail('storage_required');
    await mkdir(config.storage_dir,{recursive:true,mode:0o700});
    if (((await stat(config.storage_dir)).mode & 0o077)!==0 || ((await stat(config.master_key_file)).mode & 0o077)!==0) fail('insecure_storage_permissions');
    const master=await readFile(config.master_key_file);
    if(master.length!==32) fail('invalid_master_key');
    const vault=overrides.vault || new Vault(join(config.storage_dir,'keys'),master); master.fill(0);
    const db=new DatabaseSync(join(config.storage_dir,'journal.sqlite'));
    await chmod(join(config.storage_dir,'journal.sqlite'),0o600);
    db.exec(`PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=5000;
      CREATE TABLE IF NOT EXISTS wallets(identity TEXT PRIMARY KEY,address TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS proposals(id TEXT PRIMARY KEY,identity TEXT NOT NULL,request TEXT NOT NULL,input TEXT NOT NULL,policy TEXT NOT NULL,expires INTEGER NOT NULL,state TEXT NOT NULL,tx TEXT,summary TEXT,raw TEXT,hash TEXT,error TEXT,UNIQUE(identity,request));
      CREATE UNIQUE INDEX IF NOT EXISTS wallet_active ON proposals(identity) WHERE state IN ('signing','signed','uncertain','broadcast');`);
    const rpc=overrides.rpc || createPublicClient({transport:http(config.rpc_url,{timeout:10000,retryCount:0})});
    const gen=overrides.gen || createGenLayerClient({chain:testnetBradbury,endpoint:config.rpc_url});
    return new GenLayerCore(config,db,vault,rpc,gen);
  }
  close(){this.db.close();}
  identity(sender){
    if (!this.config.agents.includes(sender)) fail('unauthorized_sender');
    return digest([this.config.swarm_id,sender,this.config.chain_id]);
  }
  async provision(sender){
    const identity=this.identity(sender); const wallet=await this.vault.ensure(identity);
    const old=this.db.prepare('SELECT address FROM wallets WHERE identity=?').get(identity);
    if(old && old.address!==wallet.address) fail('wallet_identity_changed');
    this.db.prepare('INSERT OR IGNORE INTO wallets VALUES(?,?)').run(identity,wallet.address);
    return wallet;
  }
  wallet(identity){ return this.db.prepare('SELECT address FROM wallets WHERE identity=?').get(identity) || fail('wallet_unprovisioned'); }
  policy(){return digest([this.config.chain_id,this.config.write_enabled,this.config.recipes,this.config.max_native_value,this.config.gas_reserve,this.config.max_gas_cost]);}
  active(identity){return this.db.prepare("SELECT id,state,hash FROM proposals WHERE identity=? AND state IN ('signing','signed','uncertain','broadcast')").get(identity)||null;}
  async chain(){if(await this.rpc.getChainId()!==this.config.chain_id) fail('rpc_chain_mismatch');}
  publicProposal(row){return {prepared_id:row.id,status:row.state,expires_at:row.expires,transaction_hash:row.hash||null,error:row.error||null,transaction:row.tx?JSON.parse(row.tx):null,preview:row.summary?JSON.parse(row.summary):null};}
  proposal(identity, prepared){return this.db.prepare('SELECT * FROM proposals WHERE identity=? AND id=?').get(identity,prepared)||fail('unknown_prepared_action');}
  recipe(name, args={}, write=false){
    const recipe=this.config.recipes[name]; if(!recipe || (write && recipe.mode!=='write')) fail('unsupported_recipe');
    if(!args || typeof args!=='object' || Array.isArray(args)) fail('invalid_arguments');
    const fields=recipe.fields||{};
    if(Object.keys(args).some(k=>!Object.hasOwn(fields,k)) || Object.keys(fields).some(k=>!Object.hasOwn(args,k))) fail('invalid_arguments');
    for(const [k,rule] of Object.entries(fields)) {
      if(rule.type==='uint') { const n=integer(args[k]); if(n<integer(rule.min||'0') || n>integer(rule.max)) fail('amount_outside_limits'); }
      else if(rule.type==='address') {if(!isAddress(args[k]) || !rule.allowed?.some(a=>a.toLowerCase()===args[k].toLowerCase())) fail('address_not_allowed');}
      else if(rule.type==='enum') {if(!rule.allowed.includes(args[k])) fail('invalid_choice');}
      else fail('unsupported_field_type');
    }
    const resolve=x=>x && typeof x==='object' && Object.hasOwn(x,'field')?args[x.field]:x;
    const callArgs=(recipe.args||[]).map(resolve);
    const value=integer(String(resolve(recipe.value??'0')));
    return {recipe,callArgs,value};
  }
  async handle(sender, message){
    const identity=this.identity(sender); const action=schema.actions[message?.action];
    if(!action || Object.keys(message).some(k=> !['action',...action.required,...action.optional].includes(k)) || action.required.some(k=>!(k in message))) fail('invalid_request');
    switch(message.action){
      case 'describe':return {interface_version:schema.version,chain_id:this.config.chain_id,wallet:this.db.prepare('SELECT address FROM wallets WHERE identity=?').get(identity)||null,write_enabled:this.config.write_enabled,actions:schema.actions,limits:{max_native_value:this.config.max_native_value||'0',gas_reserve:this.config.gas_reserve||'0',max_gas_cost:this.config.max_gas_cost||'0'},pending:this.active(identity)};
      case 'assets':return {recipes:Object.entries(this.config.recipes).map(([name,r])=>({name,mode:r.mode,kind:r.kind||'evm',description:r.description||'',fields:r.fields||{},address:r.address})),coverage:'host_configured_only'};
      case 'balance':{await this.chain();const {address}=this.wallet(identity);const balance=await this.rpc.getBalance({address});return {address,asset:'GEN',decimals:18,balance_base_units:balance.toString(),pending:this.active(identity),spendable_base_units:this.active(identity)?'0':(balance>integer(this.config.gas_reserve||'0')?balance-integer(this.config.gas_reserve||'0'):0n).toString()};}
      case 'read':{await this.chain();const {recipe:r,callArgs}=this.recipe(message.recipe,message.args);if(r.mode!=='read')fail('unsupported_recipe');const result=r.kind==='intelligent'?await this.gen.readContract({address:r.address,functionName:r.function,args:callArgs}):await this.rpc.readContract({address:r.address,abi:r.abi,functionName:r.function,args:callArgs});return {result:JSON.parse(canonical(result))};}
      case 'prepare':return this.prepare(identity,message);
      case 'submit':return this.submit(identity,message.prepared_id);
      case 'status':return this.status(identity,message.prepared_id);
    }
  }
  async prepare(identity,message){
    if(!this.config.write_enabled) fail('writes_disabled');
    if(!id(message.request_id))fail('invalid_request_id');
    const input=canonical([message.recipe,message.args||{}]);
    const existing=this.db.prepare('SELECT * FROM proposals WHERE identity=? AND request=?').get(identity,message.request_id);
    if(existing){if(existing.input!==input)fail('idempotency_conflict');return this.publicProposal(existing);}
    await this.chain();const {address}=this.wallet(identity);
    const {recipe:r,callArgs,value}=this.recipe(message.recipe,message.args,true);
    if(r.kind==='intelligent')fail('intelligent_writes_not_supported');
    if(!isAddress(r.address)) fail('invalid_destination');
    if(value>integer(this.config.max_native_value||'0'))fail('native_value_limit');
    const tx={to:r.address,data:r.kind==='native'?'0x':encodeFunctionData({abi:r.abi,functionName:r.function,args:callArgs}),value:value.toString()};
    const simulation=await this.rpc.call({account:address,to:tx.to,data:tx.data,value});
    const estimatedGas=await this.rpc.estimateGas({account:address,to:tx.to,data:tx.data,value})*120n/100n;
    const fees=await this.rpc.estimateFeesPerGas();
    if(fees.maxFeePerGas===undefined)fail('unsupported_fee_envelope');
    const maxGasCost=estimatedGas*fees.maxFeePerGas;
    if(maxGasCost>integer(this.config.max_gas_cost||'0'))fail('gas_cost_limit');
    let decoded=null;
    if(r.kind!=='native' && simulation.data && simulation.data!=='0x') decoded=decodeFunctionResult({abi:r.abi,functionName:r.function,data:simulation.data});
    const preview={simulation_result:decoded??null,estimated_gas:estimatedGas.toString(),max_gas_cost_base_units:maxGasCost.toString(),native_value_base_units:value.toString(),recipe:message.recipe,arguments:message.args||{}};
    const proposal=randomBytes(16).toString('hex');
    this.db.prepare("INSERT INTO proposals(id,identity,request,input,policy,expires,state,tx,summary) VALUES(?,?,?,?,?,?,'prepared',?,?)").run(proposal,identity,message.request_id,input,this.policy(),Date.now()+this.config.ttl_seconds*1000,canonical(tx),canonical(preview));
    return this.publicProposal(this.proposal(identity,proposal));
  }
  async submit(identity,prepared){
    let row=this.proposal(identity,prepared);
    if(row.state!=='prepared')return this.publicProposal(row);
    if(!this.config.write_enabled)fail('writes_disabled');
    if(row.policy!==this.policy())fail('policy_changed');
    if(row.expires<=Date.now())fail('quote_expired');
    try {const update=this.db.prepare("UPDATE proposals SET state='signing' WHERE id=? AND state='prepared'").run(prepared);if(!update.changes)return this.publicProposal(this.proposal(identity,prepared));}
    catch(e){if(e.code?.startsWith('ERR_SQLITE'))fail('wallet_busy');throw e;}
    let signed=false;
    try {
      await this.chain();const {address}=this.wallet(identity); const tx=JSON.parse(row.tx);
      const value=BigInt(tx.value);const call={account:address,to:tx.to,data:tx.data,value};
      await this.rpc.call(call);
      const gas=await this.rpc.estimateGas(call)*120n/100n;
      const fees=await this.rpc.estimateFeesPerGas();
      if(fees.maxFeePerGas===undefined||fees.maxPriorityFeePerGas===undefined)fail('unsupported_fee_envelope');
      const gasCost=gas*fees.maxFeePerGas;
      if(gasCost>integer(this.config.max_gas_cost||'0'))fail('gas_cost_limit');
      if(await this.rpc.getBalance({address})<value+gasCost+integer(this.config.gas_reserve||'0'))fail('insufficient_balance');
      const nonce=await this.rpc.getTransactionCount({address,blockTag:'pending'});
      if(row.expires<=Date.now())fail('quote_expired');
      const raw=await this.vault.signValidatedTransaction(identity,{...tx,value,gas,nonce,chainId:this.config.chain_id,type:'eip1559',...fees});
      const hash=keccak256(raw);
      this.db.prepare("UPDATE proposals SET state='signed',raw=?,hash=? WHERE id=?").run(raw,hash,prepared);signed=true;
      const returned=await this.rpc.sendRawTransaction({serializedTransaction:raw});
      if(returned.toLowerCase()!==hash.toLowerCase())fail('rpc_hash_mismatch');
      this.db.prepare("UPDATE proposals SET state='broadcast' WHERE id=?").run(prepared);
    }catch(e){
      const code=/^[a-z_]+$/.test(e.code||'')?e.code:'execution_error';
      this.db.prepare('UPDATE proposals SET state=?,error=? WHERE id=?').run(signed?'uncertain':'rejected',code,prepared);
    }
    return this.publicProposal(this.proposal(identity,prepared));
  }
  async status(identity,prepared){
    const row=this.proposal(identity,prepared);
    if(!['signed','uncertain','broadcast'].includes(row.state))return this.publicProposal(row);
    await this.chain();let receipt;
    try{receipt=await this.rpc.getTransactionReceipt({hash:row.hash});}catch(e){if(e.name==='TransactionReceiptNotFoundError')return this.publicProposal(row);throw e;}
    if(receipt.transactionHash.toLowerCase()!==row.hash.toLowerCase())fail('invalid_receipt');
    const block=await this.rpc.getBlock({blockNumber:receipt.blockNumber});
    if(block.hash!==receipt.blockHash) return this.publicProposal(row);
    if(await this.rpc.getBlockNumber({cacheTime:0})<receipt.blockNumber+BigInt(this.config.confirmations)-1n)return this.publicProposal(row);
    if(!['success','reverted'].includes(receipt.status))fail('invalid_receipt');
    this.db.prepare('UPDATE proposals SET state=? WHERE id=?').run(receipt.status==='success'?'confirmed':'reverted',prepared);
    return this.publicProposal(this.proposal(identity,prepared));
  }
}
