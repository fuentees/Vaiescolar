'use strict';

const fs = require('node:fs');
const path = require('node:path');

const file = process.argv[2];
if (!file) throw new Error('Uso: npm run backup:verify -- caminho/do/backup.sql');
const resolved = path.resolve(file);
const stat = fs.statSync(resolved);
if (!stat.isFile() || stat.size < 1024) throw new Error('Backup ausente, vazio ou pequeno demais');
const descriptor = fs.openSync(resolved, 'r');
const buffer = Buffer.alloc(Math.min(200000, stat.size));
fs.readSync(descriptor, buffer, 0, buffer.length, 0);
fs.closeSync(descriptor);
const head = buffer.toString('utf8');
const required = ['CREATE TABLE', 'tenants', 'users', 'students', 'trips'];
const missing = required.filter((term) => !head.includes(term));
if (missing.length) throw new Error(`Backup nao parece completo; faltando: ${missing.join(', ')}`);
console.log(JSON.stringify({ ok: true, file: resolved, bytes: stat.size }, null, 2));
