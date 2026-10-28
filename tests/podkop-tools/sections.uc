// SPDX-License-Identifier: GPL-2.0-only
import * as sections from '/usr/libexec/podkop-tools/sections.uc';
import { canonical } from '/usr/libexec/podkop-tools/model.uc';
let passed = 0;
function assert(ok, message) { if (!ok) die(message); passed++; }
function copy(v) { return json(sprintf('%J', v)); }
function rejected(fn, label) { let error; try { fn(); } catch(e) { error=e.message; } assert(error=='routing_changed', label); }
let base = { outbounds: [
    {tag:'main-1-out',type:'vless',server:'node.example'},
    {tag:'main-out',type:'selector',outbounds:['main-1-out']},
    {tag:'direct-out',type:'direct'},
    {tag:'custom-out',type:'vless',server:'independent.example'},
    {tag:'antigravity-out',type:'direct',bind_interface:'wan'}
], inbounds:[{tag:'main-in',type:'mixed'}], dns:{servers:[{tag:'local-dns',type:'udp',server:'127.0.0.1'}]}, route:{final:'direct-out',rules:[{outbound:'custom-out'}],rule_set:[{tag:'custom-set',type:'local',format:'source',path:'/live/custom.json'}]} };
sections.validate_tags(base);
assert(length(sections.main_profiles(base))==1 && sections.main_profiles(base)[0].tag=='main-1-out','independent VLESS is not a managed profile');
let reader = path => 'same-content';
let before = sections.independent_snapshot(base, false, reader), updated=copy(base);
updated.outbounds[0].server='updated.example';
updated.route.rule_set[0].path='/staging/custom.json';
sections.assert_preserved(before,sections.independent_snapshot(updated,false,reader)); passed++;
assert(length(before.independent.outbounds)==3,'unowned antigravity name remains independent');
for(let key in ['outbounds','inbounds']) {
 let collision=copy(base);push(collision[key],copy(collision[key][0]));
 rejected(()=>sections.validate_tags(collision),'duplicate '+key);
}
let collision=copy(base);push(collision.dns.servers,copy(collision.dns.servers[0]));rejected(()=>sections.validate_tags(collision),'duplicate DNS tags');
collision=copy(base);push(collision.route.rule_set,copy(collision.route.rule_set[0]));rejected(()=>sections.validate_tags(collision),'duplicate ruleset tags');
let changed=copy(updated);changed.outbounds[3].server='hijacked.example';
rejected(()=>sections.assert_preserved(before,sections.independent_snapshot(changed,false,reader)),'independent outbound change');
changed=copy(updated);changed.dns.servers[0].server='127.0.0.2';
rejected(()=>sections.assert_preserved(before,sections.independent_snapshot(changed,false,reader)),'independent DNS change');
changed=copy(updated);changed.route.rules[0].outbound='main-out';
rejected(()=>sections.assert_preserved(before,sections.independent_snapshot(changed,false,reader)),'independent route change');
let dependent=copy(base);dependent.outbounds[3].detour='main-1-out';
let original=sections.independent_snapshot(dependent,false,reader);
sections.assert_preserved(original,sections.independent_snapshot(copy(dependent),false,reader));passed++;
dependent.outbounds[0].server='different-member.example';
rejected(()=>sections.assert_preserved(original,sections.independent_snapshot(dependent,false,reader)),'changed managed member referent');
let with_ag=copy(base);with_ag.outbounds[4]={tag:'antigravity-out',type:'selector',outbounds:['antigravity-1-out']};push(with_ag.outbounds,{tag:'antigravity-1-out',type:'vless',server:'node.example'});
let ag_snapshot=sections.independent_snapshot(with_ag,true,reader);with_ag.outbounds[5].server='updated.example';
sections.assert_preserved(ag_snapshot,sections.independent_snapshot(with_ag,true,reader));passed++;
assert(length(ag_snapshot.independent.outbounds)==2,'only explicitly owned AG outputs removed');
print(sprintf('%J\n',{passed}));
