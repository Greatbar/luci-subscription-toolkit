// SPDX-License-Identifier: GPL-2.0-only
// Preliminary operation requirements. Versions are diagnostics, never a gate.
export function compatibility_report(facts, versions) {
    let requirements = {
        fetch: ['fetch'], selector: ['selector'], monitoring: ['selector', 'monitoring'],
        switch: ['selector'], measurement: ['selector', 'measurement'],
        apply: ['selector', 'generation', 'measurement', 'reload'],
        rollback: ['generation', 'reload', 'backup'],
        // Recovery may switch to an accepted server without native generation.
        // A changed endpoint additionally checks the apply requirements at use.
        recovery: ['selector', 'measurement']
    };
    let capabilities = {};
    for (let name, needs in requirements) {
        let reason = null;
        for (let need in needs) if (facts[need]) { reason = facts[need]; break; }
        capabilities[name] = { available: reason == null, reason };
    }
    let pair = versions.podkop + '/' + versions.sing_box;
    let tested = versions.openwrt == '25.12.5' && index(['0.7.22/1.14.2', '0.7.14/1.12.17'], pair) >= 0;
    return { versions, warnings: tested ? [] : ['untested_versions'], capabilities };
};
