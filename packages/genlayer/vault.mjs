import { randomBytes, createCipheriv, createDecipheriv } from 'node:crypto';
import { mkdir, open, readFile, link, unlink } from 'node:fs/promises';
import { join } from 'node:path';
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts';

// Trusted host API only. Never expose this object or its transaction API to an LLM.
export class Vault {
  #root; #master;
  constructor(root, master) {
    if (!Buffer.isBuffer(master) || master.length !== 32) throw Error('invalid_master_key');
    this.#root = root; this.#master = Buffer.from(master);
  }
  #id(identity) {
    if (!/^[a-zA-Z0-9_-]{1,100}$/.test(identity)) throw Error('invalid_identity');
    return identity;
  }
  async #read(identity) {
    const id = this.#id(identity);
    const envelope = JSON.parse(await readFile(join(this.#root, `${id}.json`), 'utf8'));
    if (envelope.version !== 1) throw Error('unsupported_vault_version');
    const decipher = createDecipheriv('aes-256-gcm', this.#master, Buffer.from(envelope.iv, 'hex'));
    decipher.setAAD(Buffer.from(id));
    decipher.setAuthTag(Buffer.from(envelope.tag, 'hex'));
    const key = Buffer.concat([decipher.update(Buffer.from(envelope.ciphertext, 'hex')), decipher.final()]);
    try { return privateKeyToAccount(`0x${key.toString('hex')}`); } finally { key.fill(0); }
  }
  async ensure(identity) {
    const id = this.#id(identity);
    try { return { address: (await this.#read(id)).address }; }
    catch (e) { if (e.code !== 'ENOENT') throw e; }
    await mkdir(this.#root, { recursive: true, mode: 0o700 });
    const key = Buffer.from(generatePrivateKey().slice(2), 'hex');
    const iv = randomBytes(12);
    const cipher = createCipheriv('aes-256-gcm', this.#master, iv);
    cipher.setAAD(Buffer.from(id));
    const ciphertext = Buffer.concat([cipher.update(key), cipher.final()]);
    key.fill(0);
    const envelope = { version: 1, iv: iv.toString('hex'), tag: cipher.getAuthTag().toString('hex'), ciphertext: ciphertext.toString('hex') };
    const temp = join(this.#root, `.${id}-${randomBytes(12).toString('hex')}`);
    const file = await open(temp, 'wx', 0o600);
    try { await file.writeFile(JSON.stringify(envelope)); await file.sync(); } finally { await file.close(); }
    try { await link(temp, join(this.#root, `${id}.json`)); }
    catch (e) { if (e.code !== 'EEXIST') throw e; }
    finally { await unlink(temp); }
    const dir = await open(this.#root, 'r');
    try { await dir.sync(); } finally { await dir.close(); }
    return { address: (await this.#read(id)).address };
  }
  async signValidatedTransaction(identity, transaction) {
    if (transaction.chainId !== 4221) throw Error('wrong_chain');
    return (await this.#read(identity)).signTransaction(transaction);
  }
}
