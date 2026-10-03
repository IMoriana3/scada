/* Compare checked-out counterparts without credentials or network access. */
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const root=path.resolve(__dirname,'..'),other=process.argv[2];
if(!other){console.error('Falta ruta al repositorio contraparte. Paridad no comprobada.');process.exit(2);}
let failed=false;
for(const name of ['operacion-contract.js','operations-v1.json']){
  try{
    const a=fs.readFileSync(path.join(root,'contracts',name));
    const b=fs.readFileSync(path.resolve(other,'contracts',name));
    if(!a.equals(b))throw Error('Contenido distinto');
    console.log(`${name}: idéntico · SHA256 ${crypto.createHash('sha256').update(a).digest('hex')}`);
  }catch(e){failed=true;console.error(`${name}: ${e.message}`);}
}
process.exitCode=failed?1:0;
