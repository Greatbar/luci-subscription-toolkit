// SPDX-License-Identifier: GPL-2.0-only
// Pure decisions: no I/O, clocks or mutable router state.
export function remaining(deadline, now, cap, reserve) {
    let left = deadline - now - (reserve ?? 0);
    return left > 0 ? min(left, cap) : 0;
};
export function priority_order(nodes, preferred, priorities) {
    let result=[], seen={};
    for(let id in [preferred, ...(priorities ?? [])]) {
        let node=filter(nodes,n=>n.id==id)[0];
        if(node && !seen[id]){push(result,node);seen[id]=true;}
    }
    for(let node in nodes)if(!seen[node.id]){push(result,node);seen[node.id]=true;}
    return result;
};
export function observe(previous, key, now, ok, delay, config) {
    let timeout=config.failure_seconds ?? 120, count=config.failure_count ?? 3;
    let contiguous=previous?.key==key && now>=previous.at && now-previous.at<=90;
    if(contiguous && now-previous.at<45)return previous;
    let o={key,at:now,ok,delay,failures:0,first_failed:null,high_since:null,successes:0,success_since:null};
    if(!ok){o.failures=contiguous?previous.failures+1:1;o.first_failed=contiguous && previous.failures?previous.first_failed:now;}
    else {
        o.successes=contiguous && previous.ok?previous.successes+1:1;
        o.success_since=contiguous && previous.ok?previous.success_since:now;
        if(delay!=null && delay>(config.latency_threshold_ms ?? 1000))o.high_since=contiguous && previous.high_since!=null?previous.high_since:now;
    }
    o.confirmed=!ok && o.failures>=count && now-o.first_failed>=timeout;
    o.high=ok && o.high_since!=null && now-o.high_since>=(config.latency_duration_seconds ?? 300);
    return o;
};
export function reserve_slot(nodes, active, preferred, progress, now) {
    let others=filter(nodes,n=>n.id!=active && n.id!=preferred);
    if(active!=preferred && now-(progress.preferred_at ?? 0)>=300){
        let p=filter(nodes,n=>n.id==preferred)[0];if(p)return {id:p.id,preferred_at:now,cursor:progress.cursor ?? 0};
    }
    if(active==preferred)others=filter(nodes,n=>n.id!=active);
    if(!length(others))return null;
    let cursor=(progress.cursor ?? 0)%length(others);
    return {id:others[cursor].id,cursor:(cursor+1)%length(others),preferred_at:progress.preferred_at ?? 0};
};
export function nonemergency_allowed(state,now,config) {
    if(now-(state.last_switch ?? 0)<(config.cooldown_seconds ?? 600))return false;
    return length(filter(state.transitions ?? [],t=>t<=now && now-t<1800))<3;
};
export function latency_better(active,candidate,config) {
    return active!=null && candidate!=null && candidate<=(config.latency_threshold_ms ?? 1000)*0.8 && active-candidate>=max(config.improvement_ms ?? 50,active*(config.improvement_percent ?? 20)/100);
};
export function selection_event(state,actual,now,boot) {
    let s={...(state ?? {})};
    if(s.intent && actual==s.intent.to){s.selected_id=actual;s.reason=s.intent.reason;delete s.intent;return s;}
    if(s.intent && actual==s.intent.from){delete s.intent;return s;}
    if(!s.preferred_id || s.selected_id!=actual){s.preferred_id=actual;s.selected_id=actual;s.origin=boot?'boot_adopted_unknown':'external';s.reason=s.origin;s.last_switch=now;s.transitions=[];delete s.intent;}
    return s;
};
