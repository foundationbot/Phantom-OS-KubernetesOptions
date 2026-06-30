"""
Common utility functions for the AI API server.
"""
import os


def get_nixos_command(cmd: str) -> str:
    """
    Get command path, checking NixOS path first.

    On NixOS systems, binaries are located at /run/current-system/sw/bin/
    instead of /usr/bin/. This function checks for the NixOS path first
    and falls back to the bare command name for standard systems.

    Args:
        cmd: The command name (e.g., 'docker', 'sudo', 'systemctl')

    Returns:
        Full path to the command on NixOS, or bare command name otherwise
    """
    nixos_path = f'/run/current-system/sw/bin/{cmd}'
    if os.path.exists(nixos_path):
        return nixos_path
    return cmd
