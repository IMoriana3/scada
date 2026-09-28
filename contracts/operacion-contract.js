/* Canonical behavior contract operations-v1. Browser and Node, no dependencies. */
(function(root){
  function puedeCerrar(e){
    if(!e || typeof e!=="object")return false;
    const number=v=>(typeof v==="number"||typeof v==="string")&&/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(String(v).trim())&&Number.isFinite(Number(v))?Number(v):NaN;
    const age=number(e.adquisicion_s),origin=number(e.edad_origen_s);
    return e.origen_verificado===true&&e.diagnostico===true&&e.historico===false&&e.salud==='OK'
      &&typeof e.nota==='string'&&e.nota.trim().length>0&&age>=0&&origin>=0&&age<=300&&age+origin<=300;
  }
  const api={version:1,estados:['abierto','en curso','cerrado'],puedeCerrar};
  if(typeof module==='object'&&module.exports)module.exports=api;
  else root.OperacionContrato=api;
})(typeof globalThis!=='undefined'?globalThis:this);
