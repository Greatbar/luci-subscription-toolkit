// SPDX-License-Identifier: GPL-2.0-only
// Appended to the real backend definitions by the unit runner (no network).
let ag_passed=0;
function ag_assert(ok,label) { if(!ok)die(label);ag_passed++; }
function ag_copy(value) {return json(sprintf('%J',value));}
function ag_rejected(fn,label) {
    let error;try{fn();}catch(e){error=e.message;}
    ag_assert(index(['state_conflict','antigravity_node_missing','routing_changed'],error)>=0,label);
}
let ag_node={id:'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',name:'A',outbound:{type:'vless',server:'node.example',server_port:443,uuid:'00000000-0000-4000-8000-000000000001'}};
let ag_fields={subscription_node_id:ag_node.id,proxy_config_type:'selector',selector_proxy_links:[proxy_uri(ag_node)]};
let ag_config={get:function(package,section,key){return key ? ag_fields[key] : 'section';}};
let ag_generated={outbounds:[{...ag_node.outbound,tag:'antigravity-1-out'},{type:'selector',tag:'antigravity-out',outbounds:['antigravity-1-out']}]};
for(let tag in ['antigravity-99-out','antigravity-000-out','custom-out']) {
    let value=ag_copy(ag_generated);push(value.outbounds,{type:'direct',tag});
    verify_antigravity(ag_config,[ag_node],value,'state_conflict');ag_passed++;
}
let ag_bad=ag_copy(ag_generated);ag_bad.outbounds[0].server_port=444;
ag_rejected(()=>verify_antigravity(ag_config,[ag_node],ag_bad,'state_conflict'),'changed owned profile');
ag_bad=ag_copy(ag_generated);ag_bad.outbounds[1].outbounds=['custom-out'];
ag_rejected(()=>verify_antigravity(ag_config,[ag_node],ag_bad,'state_conflict'),'changed owned membership');
ag_bad=ag_copy(ag_generated);push(ag_bad.outbounds,ag_copy(ag_bad.outbounds[0]));
ag_rejected(()=>verify_antigravity(ag_config,[ag_node],ag_bad,'state_conflict'),'duplicate owned tag');
ag_fields.subscription_node_id=null;
verify_antigravity(ag_config,[ag_node],{outbounds:[{type:'direct',tag:'antigravity-out'}]},'state_conflict');ag_passed++;
ag_fields.subscription_node_id=ag_node.id;ag_fields.proxy_config_type='outbound';ag_fields.outbound_json=sprintf('%J',ag_node.outbound);
verify_antigravity(ag_config,[ag_node],{outbounds:[{...ag_node.outbound,tag:'antigravity-out'},{type:'direct',tag:'antigravity-99-out'}]},'state_conflict');ag_passed++;
ag_fields.subscription_node_id='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
ag_rejected(()=>verify_antigravity(ag_config,[ag_node],{outbounds:[{...ag_node.outbound,tag:'antigravity-out'}]},'state_conflict'),'invalid explicit binding');
print(sprintf('%J\n',{ag_passed}));
