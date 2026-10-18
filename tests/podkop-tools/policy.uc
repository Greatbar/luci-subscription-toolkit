// SPDX-License-Identifier: GPL-2.0-only
import { priority_order, observe, reserve_slot, nonemergency_allowed, latency_better, remaining, selection_event } from '/usr/libexec/podkop-tools/policy.uc';
let n=0;
function check(ok,label){if(!ok)die(label);n++;}
let nodes=[{id:'a'},{id:'b'},{id:'c'},{id:'d'}];
check(join('',map(priority_order(nodes,'b',['d','c']),x=>x.id))=='bdca','preferred_and_reserves');
let o=null;
for(let t in [0,60,120])o=observe(o,'signature',t,false,null,{});
check(o.confirmed && o.failures==3,'three_failures_over120');
o=observe(o,'signature',121,false,null,{});check(o.failures==3,'rapid_retry_no_vote');
let skipped=observe(o,'signature',241,false,null,{});check(skipped.failures==1,'missed_minute_resets_failure_window');
o=observe(o,'signature',500,false,null,{});check(!o.confirmed && o.failures==1,'gap_no_confirmation');
o=observe(o,'changed',560,false,null,{});check(o.failures==1,'profile_resets');
check(reserve_slot(nodes,'c','a',{cursor:0,preferred_at:0},600).id=='a','preferred_every5m');
check(reserve_slot(nodes,'c','a',{cursor:0,preferred_at:600},660).id=='b','other_reserves_progress');
check(!nonemergency_allowed({last_switch:500,transitions:[]},600,{}),'cooldown');
check(!nonemergency_allowed({last_switch:0,transitions:[100,200,300]},1000,{}),'nonemergency_rate');
check(latency_better(1500,800,{}) && !latency_better(1500,1400,{}),'fresh_comparison_margin');
check(remaining(15,12,5,1)==2 && remaining(15,15,5,0)==0,'deadline_clamps_each_operation');
let s=selection_event({preferred_id:'a',selected_id:'b',intent:{from:'b',to:'c',reason:'outage'}},'c',100);
check(s.preferred_id=='a' && s.selected_id=='c' && s.reason=='outage','own_switch_not_manual');
s=selection_event(s,'d',160);check(s.preferred_id=='d' && s.origin=='external','external_switch_adopted');
s=selection_event({preferred_id:'a',selected_id:'b'},'c',200,true);
check(s.preferred_id=='c' && s.origin=='boot_adopted_unknown','boot_does_not_overwrite_live');
s=selection_event({preferred_id:'a',selected_id:'b',intent:{from:'b',to:'c',reason:'outage'}},'b',300,true);check(!s.intent && s.preferred_id=='a','unapplied_intent_cleared');
print(sprintf('%J\n',{passed:n}));
