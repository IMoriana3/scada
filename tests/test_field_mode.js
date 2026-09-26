const assert = require("assert");
const Field = require("../field-mode.js");

(function testAssetIdentityIsMandatory(){
  assert.throws(() => Field.newInspection({}, null), /asset_id required/);
  const x = Field.newInspection({asset_id:"11111111-1111-1111-1111-111111111111", layout_key:"TK-1"}, {health:"ok"});
  assert.equal(x.asset_id, "11111111-1111-1111-1111-111111111111");
  assert.equal(x.layout_key, "TK-1");
  assert.equal(x.provenance.persistence, "device-local");
  assert.equal(x.provenance.server_sync, "UNAVAILABLE_UNTIL_CONTRACT_APPROVED");
})();

(function testAngleDeviationDoesNotInventConvention(){
  assert.equal(Field.angleDeviation(12.5, 10), 2.5);
  assert.equal(Field.angleDeviation(null, 10), null);
  assert.equal(Field.angleDeviation(10, undefined), null);
})();

(function testStringComparisonUsesMedian(){
  const rows=[
    {label:"S1",value:10,modules:30},
    {label:"S2",value:10.2,modules:30},
    {label:"S3",value:7,modules:30}
  ];
  const out=Field.compareStrings(rows,"A");
  assert.equal(out.length,3);
  assert.equal(out[0].median,10);
  assert.equal(out[0].status,"ok");
  assert.equal(out[2].status,"alarm");
})();

(function testPowerComparisonNormalizesByModuleCount(){
  const rows=[
    {label:"S1",value:3,modules:30},
    {label:"S2",value:2,modules:20}
  ];
  const out=Field.compareStrings(rows,"kW");
  assert.equal(out[0].normalized,100);
  assert.equal(out[1].normalized,100);
  assert(out.every(r=>r.status==="ok"));
})();

(function testFinishKeepsAssetIdentity(){
  const a={asset_id:"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"};
  const x=Field.newInspection(a,null);
  const y=Field.finishInspection(x);
  assert.equal(y.asset_id,a.asset_id);
  assert(y.completed_at);
})();

console.log("field-mode tests OK");
