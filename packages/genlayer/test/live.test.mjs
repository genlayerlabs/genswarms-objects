import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {randomBytes} from 'node:crypto';
import {GenLayerCore} from '../core.mjs';
test('live Bradbury identity and unfunded native balance, read-only', {skip:!process.env.GENLAYER_LIVE_TEST},async t=>{
 const root=await mkdtemp(join(tmpdir(),'genlayer-live-'));t.after(()=>rm(root,{recursive:true,force:true}));
 const master=join(root,'master');await writeFile(master,randomBytes(32),{mode:0o600});
 const core=await GenLayerCore.open({swarm_id:'live-check',agents:['alice'],storage_dir:join(root,'vault'),master_key_file:master});t.after(()=>core.close());
 await core.provision('alice');const balance=await core.handle('alice',{action:'balance'});
 assert.equal(balance.asset,'GEN');assert.equal(balance.decimals,18);assert.equal(balance.balance_base_units,'0');
 assert.equal((await core.handle('alice',{action:'describe'})).write_enabled,false);
});
