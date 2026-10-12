// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 LuCI Subscription Toolkit contributors
// Offline validation of a synthetic provider fixture against an expected outbound fixture.
import * as fs from 'fs';
import { cursor } from 'uci';
import { parse_provider, canonical, proxy_uri } from '/usr/libexec/podkop-tools/model.uc';
let parsed = parse_provider(fs.readfile(ARGV[0]));
let saved = json(fs.readfile(ARGV[1]));
let existing = filter(saved.outbounds, o => o.type == 'vless');
if (length(existing) != length(parsed.nodes)) die('provider_count_mismatch');
for (let o in existing) {
    delete o.tag;
    if (!length(filter(parsed.nodes, n => canonical(n.outbound) == canonical(o)))) die('provider_parameters_mismatch');
}
let config = { log: { disabled: true }, inbounds: [], outbounds: map(parsed.nodes, (n, i) => {
    let o = n.outbound; o.tag = 'test-' + i; return o;
}), route: { final: 'test-0' } };
fs.writefile(ARGV[2], sprintf('%J', config)); fs.chmod(ARGV[2], 0600);
if (ARGV[3]) {
    let uci = cursor('/tmp/podkop-tools/job/uci', '/tmp/podkop-tools/job/delta', '');
    if (!uci.set('podkop', 'main', 'selector_proxy_links', map(parsed.nodes, proxy_uri)) ||
        !uci.set('podkop', 'settings', 'config_path', '/tmp/podkop-tools/job/generated.json') || !uci.commit('podkop')) die('offline_staging_failed');
}
print('PASS synthetic provider format and exact stock outbound parameters: ', length(parsed.nodes), ' nodes\n');
