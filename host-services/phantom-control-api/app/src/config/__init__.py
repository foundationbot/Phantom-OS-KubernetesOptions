"""
Config package for Phantom Control API

The main configuration is in robotConfig.py.
settings.py provides backward compatibility.
"""

from .robotConfig import RobotConfig

__all__ = ['RobotConfig']
