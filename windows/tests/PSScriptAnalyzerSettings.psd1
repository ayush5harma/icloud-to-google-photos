@{
    # Warnings fail the build as errors do; Information-level suggestions do not.
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # The interactive commands (setup, arm, config, install) print coloured
        # progress for a person at a terminal, as the macOS scripts' printf
        # does, and Write-Host is the host API for exactly that.
        'PSAvoidUsingWriteHost',
        # These functions are the internal steps of an unattended pipeline.
        # Its dry runs are its own documented flags (-Check, -ReclaimDryRun,
        # offload -DryRun), not a -WhatIf nobody would pass to a scheduled task.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
