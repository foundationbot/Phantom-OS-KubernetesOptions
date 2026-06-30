"""
Centralized Robot Configuration

This file contains all hardcoded values and configuration constants for the
Phantom Control API. All robot-specific paths, container names, and default
values should be defined here for easy maintenance and deployment across
different environments (radon, argentum, etc.).

Usage:
    from config.robotConfig import RobotConfig

    # Access values
    container = RobotConfig.PHANTOM_CONTAINER_NAME
    models_dir = RobotConfig.PHANTOM_MODELS
"""

import os


class RobotConfig:
    """Centralized configuration for robot-specific values."""

    # =========================================================================
    # API Server Configuration
    # =========================================================================
    API_HOST = os.getenv("API_HOST", "0.0.0.0")
    API_PORT = int(os.getenv("API_PORT", "5000"))

    # =========================================================================
    # Service Configuration
    # =========================================================================
    SERVICE_NAME = os.getenv("SERVICE_NAME", "phantom-positronic-control.service")

    # =========================================================================
    # Docker Configuration
    # =========================================================================
    DOCKER_SOCKET_PATH = os.getenv("DOCKER_SOCKET_PATH", "/var/run/docker.sock")
    DOCKER_COMMAND = os.getenv("DOCKER_COMMAND", "/run/current-system/sw/bin/docker")

    # =========================================================================
    # Logging Configuration
    # =========================================================================
    LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO")
    LOG_FILE = os.getenv("LOG_FILE", "./phantom_control_api.log")

    # =========================================================================
    # WebSocket Configuration
    # =========================================================================
    WEBSOCKET_MAX_CONNECTIONS = int(os.getenv("WEBSOCKET_MAX_CONNECTIONS", "100"))

    # =========================================================================
    # System Statistics Configuration
    # =========================================================================
    STATS_COLLECTION_INTERVAL = int(os.getenv("STATS_COLLECTION_INTERVAL", "3600"))  # 1 hour
    STATS_HISTORY_SIZE = int(os.getenv("STATS_HISTORY_SIZE", "24"))  # 24 hours

    # =========================================================================
    # Dashboard Configuration
    # =========================================================================
    DASHBOARD_AUTO_REFRESH = int(os.getenv("DASHBOARD_AUTO_REFRESH", "30"))

    # =========================================================================
    # Robot Controller Configuration (Java/EtherCAT)
    # =========================================================================
    PHANTOM_CONTROLLER_RUNNER_PATH = os.getenv(
        "PHANTOM_CONTROLLER_RUNNER_PATH",
        "/home/gaurav/phantom/bin/PhantomControllerRunner"
    )
    PHANTOM_CONTROLLER_JSON_FILE = os.getenv("PHANTOM_CONTROLLER_JSON_FILE", "phantom-0001.json")
    PHANTOM_CONTROLLER_INTERFACE = os.getenv("PHANTOM_CONTROLLER_INTERFACE", "ecat1")

    # Controller restart method
    USE_SUPERVISORD = os.getenv("USE_SUPERVISORD", "true").lower() in ("true", "1", "yes", "on")

    # =========================================================================
    # Phantom Container Configuration
    # =========================================================================
    PHANTOM_CONTAINER_NAME = os.getenv("PHANTOM_CONTAINER_NAME", "positronic_phantom")
    PHANTOM_DEFAULT_CPUSET = os.getenv("PHANTOM_DEFAULT_CPUSET", "0-14")

    # =========================================================================
    # Policy/Models Configuration
    # =========================================================================
    # PHANTOM_MODELS is set by NixOS shell.nix, POLICIES_DIRECTORY for backward compatibility
    PHANTOM_MODELS = os.getenv(
        "PHANTOM_MODELS",
        os.getenv("POLICIES_DIRECTORY", "/home/gaurav/models")
    )
    # Alias for backward compatibility
    POLICIES_DIRECTORY = PHANTOM_MODELS

    # =========================================================================
    # Phantom Script/Source Directories
    # =========================================================================
    PHANTOM_SCRIPT_DIRECTORY = os.getenv(
        "PHANTOM_SCRIPT_DIRECTORY",
        "/home/gaurav/foundation/ai-nix-phantom-apps"
    )
    PHANTOM_SRC_HOME = os.getenv(
        "PHANTOM_SRC_HOME",
        "/home/gaurav/foundation/repository-group"
    )

    # =========================================================================
    # Positronic Control Configuration
    # =========================================================================
    POSITRONIC_CONTROL_PATH = os.getenv(
        "POSITRONIC_CONTROL_PATH",
        "/home/gaurav/foundation/positronic_control"
    )

    # =========================================================================
    # Docker Compose Projects Configuration
    # =========================================================================
    # Maps friendly project names to their compose file paths
    # If systemd_service is set, use systemctl for start/stop/restart operations
    COMPOSE_PROJECTS = {
        "operator-ui": {
            "path": "/home/operator/repos/argus/operator_ui",
            "file": "docker-compose-qa.yml",
            "systemd_service": "argus-operator-ui"
        }
    }

    # =========================================================================
    # Java Controller Configuration (Systemd Services)
    # =========================================================================
    JAVA_CONTROLLER_SERVICE = "java-controller"
    JAVA_CONTROLLER_SHM_SERVICE = "java-controller-shm"
    JAVA_PROCESS_PATTERN = "PhantomJavaPolicyRunner"

    # =========================================================================
    # Static Files Configuration
    # =========================================================================
    STATIC_DIR = os.getenv("STATIC_DIR", "./static")

    # =========================================================================
    # ROS Configuration
    # =========================================================================
    DEFAULT_ROS_DOMAIN_ID = 101

    # =========================================================================
    # User Home and Cache Directories
    # =========================================================================
    HOME_DIR = os.getenv("HOME", "/home/gaurav")
    TORCH_HOME = os.getenv("TORCH_HOME", f"{HOME_DIR}/.cache/torch")
    HF_HUB_CACHE = os.getenv("HF_HUB_CACHE", f"{HOME_DIR}/.cache/huggingface")

    # =========================================================================
    # Container Internal Paths (inside Docker)
    # =========================================================================
    CONTAINER_WORKSPACE = "/src/workspace"
    CONTAINER_ROS_SETUP = "/opt/ros/humble/setup.bash"
    CONTAINER_AMR_SETUP = "/amr_ws/install/setup.bash"
    CONTAINER_WORKSPACE_SETUP = "/src/workspace/install/setup.bash"

    # =========================================================================
    # Build/Policy Log File Paths (inside container)
    # =========================================================================
    POLICY_BUILD_LOG = "/tmp/policy_build.log"
    POLICY_RUN_LOG = "/tmp/policy_run.log"


# For convenience, allow direct import of the class
__all__ = ['RobotConfig']
