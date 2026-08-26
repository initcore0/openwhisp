#!/bin/bash
# Example script step for the `commit-message` script plugin.
#
# The host contract is exactly `ScriptRunner`'s: the step's input arrives on STDIN,
# the replacement text is whatever this writes to STDOUT, and any failure (non-zero
# exit, timeout, empty output) keeps the input unchanged. So a script step is safe to
# add to a pipeline: the worst case is that it does nothing.
#
# This one drops the ``` fences a chatty model sometimes wraps its reply in, and trims
# blank lines at the top and bottom.
set -euo pipefail

sed -e '/^[[:space:]]*```/d' \
    | sed -e '/./,$!d' \
    | awk 'NF {p = 1} p'
