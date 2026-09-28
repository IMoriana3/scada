const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const root=path.join(__dirname,'..');
const vectors=JSON.parse(fs.readFileSync(path.join(root,'contracts/operations-v1.json'),'utf8'));
const policy=require('../contracts/operacion-contract.js');
assert.deepEqual(policy.estados,vectors.states);
for(const c of vectors.close_cases)assert.equal(policy.puedeCerrar(c.input),c.allowed,c.id);
assert.equal(fs.readFileSync(path.join(root,'tools/tcu-toolbox/contracts/operations-v1.json'),'utf8'),fs.readFileSync(path.join(root,'contracts/operations-v1.json'),'utf8'));
console.log('Operations shared contract: JS vectors and Toolbox fixture identical');
