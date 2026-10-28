#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Shared AG/independent-section suite in the exclusively owned native fixture."""
from sections_integration import scenarios


def custom(state, start_exit, endpoint):
    # The regular runner prepares its documented current stock profile.
    context = {'profile': 'current', 'podkop': '0.7.22', 'sing_box': '1.14.2', 'lab': l.LAB}
    scenarios(l, context, state, start_exit, endpoint)
