// SPDX-License-Identifier: GPL-2.0-only
// Native sections are independent unless their profiles are explicitly managed.
import { canonical } from '/usr/libexec/podkop-tools/model.uc';

function unique_tags(items) {
    let seen = {};
    for (let item in items ?? []) {
        if (!item.tag) continue;
        if (seen[item.tag]) die('routing_changed');
        seen[item.tag] = true;
    }
}
export function validate_tags(config) {
    unique_tags(config.outbounds); unique_tags(config.inbounds);
    unique_tags(config.dns?.servers); unique_tags(config.route?.rule_set);
};
function group_members(config, tag) {
    let groups = filter(config.outbounds ?? [], o => o.tag == tag);
    if (length(groups) != 1) die('routing_changed');
    let group = groups[0];
    if (group.type != 'selector') return [];
    if (type(group.outbounds) != 'array' || !length(group.outbounds)) die('routing_changed');
    return group.outbounds;
}
export function main_profiles(config) {
    validate_tags(config);
    return map(group_members(config, 'main-out'), tag => {
        let nodes = filter(config.outbounds ?? [], o => o.tag == tag);
        if (length(nodes) != 1 || nodes[0].type != 'vless') die('routing_changed');
        return nodes[0];
    });
};
function member_references(value, members, found, parent_key) {
    if (type(value) == 'object') {
        for (let key, child in value) member_references(child, members, found, key);
    } else if (type(value) == 'array') {
        for (let child in value) member_references(child, members, found, parent_key);
    } else if (type(value) == 'string' && index(members, value) >= 0 &&
        index(['outbound', 'outbounds', 'detour', 'download_detour', 'default'], parent_key) >= 0) found[value] = true;
}
export function independent_snapshot(config, owned_ag, read_ruleset) {
    validate_tags(config);
    let members = [...group_members(config, 'main-out')], managed = ['main-out'];
    if (owned_ag) {
        push(managed, 'antigravity-out');
        members = [...members, ...group_members(config, 'antigravity-out')];
    }
    managed = [...managed, ...members];
    let view = json(sprintf('%J', config));
    view.outbounds = filter(view.outbounds ?? [], o => index(managed, o.tag) < 0);
    // Local rulesets move into staging, but their contents must not change.
    for (let rule in view.route?.rule_set ?? []) if (rule.type == 'local' && rule.path) {
        rule.path = read_ruleset(rule.path);
    }
    let refs = {}, referenced = {};
    member_references(view, members, refs, null);
    for (let tag in keys(refs)) referenced[tag] = json(sprintf('%J', filter(config.outbounds ?? [], o => o.tag == tag)[0]));
    return { independent: view, referenced };
};
export function assert_preserved(before, after) {
    if (canonical(before) != canonical(after)) die('routing_changed');
};
