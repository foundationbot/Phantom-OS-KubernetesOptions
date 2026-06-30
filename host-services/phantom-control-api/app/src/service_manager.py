#!/usr/bin/env python3
"""
Service Manager Module

This module contains all service management classes for the Phantom Control API.
"""

import subprocess
import sys
import time
import os
import re
import logging
from typing import Dict, List, Optional, Any, Tuple
from datetime import datetime
from pathlib import Path

# Import centralized robot configuration
from config.robotConfig import RobotConfig

# Get logger
logger = logging.getLogger(__name__)


class ServiceManager:
    """Manages the positronic control systemd service"""

    def __init__(self, service_name: str):
        """
        Initialize ServiceManager

        Args:
            service_name: Name of the systemd service to manage
        """
        self.service_name = service_name

    def get_service_status(self) -> Dict[str, Any]:
        """Get service status"""
        try:
            result = subprocess.run(
                ['systemctl', 'is-active', self.service_name],
                capture_output=True,
                text=True,
                check=False
            )
            is_active = result.stdout.strip() == 'active'

            # Get detailed status
            result = subprocess.run(
                ['systemctl', 'show', self.service_name, '--property=ActiveState,SubState,LoadState'],
                capture_output=True,
                text=True,
                check=False
            )

            status_info = {}
            for line in result.stdout.strip().split('\n'):
                if '=' in line:
                    key, value = line.split('=', 1)
                    status_info[key] = value

            return [{
                "name": self.service_name,
                "is_active": is_active,
                "status": result.stdout.strip(),
                "details": status_info,
                "timestamp": datetime.now().isoformat(),
                "statename": "RUNNING" if is_active else "STOPPED"
            }]
        except Exception as e:
            logger.error(f"Error getting service status: {e}")
            return [{
                "name": self.service_name,
                "is_active": False,
                "status": "error",
                "error": str(e),
                "timestamp": datetime.now().isoformat(),
                "statename": "STOPPED"
            }]

    def get_service_logs(self, lines: int = 100) -> Dict[str, Any]:
        """Get service logs"""
        try:
            result = subprocess.run(
                ['journalctl', '-u', self.service_name, '-n', str(lines), '--no-pager'],
                capture_output=True,
                text=True,
                check=True
            )

            logs = result.stdout.strip().split('\n')

            return {
                "service_name": self.service_name,
                "lines": len(logs),
                "logs": logs,
                "timestamp": datetime.now().isoformat()
            }
        except subprocess.CalledProcessError as e:
            logger.error(f"Error getting service logs: {e}")
            return {
                "service_name": self.service_name,
                "lines": 0,
                "logs": [],
                "error": str(e),
                "timestamp": datetime.now().isoformat()
            }
        except Exception as e:
            logger.error(f"Unexpected error getting service logs: {e}")
            return {
                "service_name": self.service_name,
                "lines": 0,
                "logs": [],
                "error": str(e),
                "timestamp": datetime.now().isoformat()
            }


class RebootManager:
    """Manages system reboot"""

    @staticmethod
    def reboot_system() -> Dict[str, Any]:
        """Reboot the system"""
        try:
            logger.info("System reboot requested")

            # Try different reboot methods
            reboot_methods = [
                ['systemctl', 'reboot'],
                ['shutdown', '-r', 'now'],
                ['reboot']
            ]

            for method in reboot_methods:
                try:
                    subprocess.run(method, check=True, timeout=5)
                    return {
                        "success": True,
                        "message": "System reboot initiated",
                        "method": ' '.join(method),
                        "timestamp": datetime.now().isoformat()
                    }
                except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                    continue

            return {
                "success": False,
                "message": "All reboot methods failed",
                "timestamp": datetime.now().isoformat()
            }

        except Exception as e:
            logger.error(f"Error rebooting system: {e}")
            return {
                "success": False,
                "message": f"Reboot failed: {str(e)}",
                "error": str(e),
                "timestamp": datetime.now().isoformat()
            }


class RobotControllerManager:
    """Manages the robot controller application"""

    def __init__(
        self,
        runner_path: str,
        json_file: str,
        interface: str,
        use_supervisord: bool = True
    ):
        """
        Initialize RobotControllerManager

        Args:
            runner_path: Path to PhantomControllerRunner
            json_file: Path to JSON configuration file
            interface: Network interface to use
            use_supervisord: Whether to use supervisord for restart
        """
        self.runner_path = runner_path
        self.json_file = json_file
        self.interface = interface
        self.use_supervisord = use_supervisord

    def validate_controller_files(self) -> Dict[str, Any]:
        """Validate that PhantomControllerRunner and JSON file exist"""
        try:
            # Check if PhantomControllerRunner exists
            if not os.path.exists(self.runner_path):
                return {
                    "valid": False,
                    "error": f"PhantomControllerRunner not found at: {self.runner_path}",
                    "path": self.runner_path
                }

            # Check if JSON file exists
            if not os.path.exists(self.json_file):
                return {
                    "valid": False,
                    "error": f"JSON configuration file not found: {self.json_file}",
                    "path": self.json_file
                }

            # Check if PhantomControllerRunner is executable
            if not os.access(self.runner_path, os.X_OK):
                return {
                    "valid": False,
                    "error": f"PhantomControllerRunner is not executable: {self.runner_path}",
                    "path": self.runner_path
                }

            return {
                "valid": True,
                "message": "All required files exist and are accessible",
                "controller_path": self.runner_path,
                "json_file": self.json_file,
                "interface": self.interface
            }

        except Exception as e:
            logger.error(f"Error validating controller files: {e}")
            return {
                "valid": False,
                "error": f"Validation error: {str(e)}",
                "timestamp": datetime.now().isoformat()
            }

    def restart_controller(self) -> Dict[str, Any]:
        """Restart the robot controller application"""
        try:
            logger.info("Robot controller restart requested")

            # Check if supervisord should be used
            if self.use_supervisord:
                return self._restart_with_supervisord()
            else:
                return self._restart_with_direct_method()

        except Exception as e:
            logger.error(f"Error restarting robot controller: {e}")
            return {
                "success": False,
                "message": f"Failed to restart robot controller: {str(e)}",
                "error": str(e),
                "timestamp": datetime.now().isoformat()
            }

    def _restart_with_supervisord(self) -> Dict[str, Any]:
        """Restart the robot controller using supervisord"""
        try:
            logger.info("Using supervisord to restart robot controller")

            # Stop phantom_apps services
            stop_cmd = ['supervisorctl', 'stop', 'phantom_apps:*']
            logger.info(f"Stopping phantom_apps services: {' '.join(stop_cmd)}")

            stop_result = subprocess.run(
                stop_cmd,
                capture_output=True,
                text=True,
                check=False
            )

            if stop_result.returncode != 0:
                logger.warning(f"Error stopping phantom_apps services: {stop_result.stderr}")

            # Wait a moment for services to stop
            time.sleep(2)

            # Start phantom_apps services
            start_cmd = ['supervisorctl', 'start', 'phantom_apps:*']
            logger.info(f"Starting phantom_apps services: {' '.join(start_cmd)}")

            start_result = subprocess.run(
                start_cmd,
                capture_output=True,
                text=True,
                check=False
            )

            if start_result.returncode == 0:
                return {
                    "success": True,
                    "message": "Robot controller restarted successfully using supervisord",
                    "method": "supervisord",
                    "stop_command": ' '.join(stop_cmd),
                    "start_command": ' '.join(start_cmd),
                    "stop_output": stop_result.stdout,
                    "start_output": start_result.stdout,
                    "timestamp": datetime.now().isoformat()
                }
            else:
                return {
                    "success": False,
                    "message": "Failed to restart robot controller using supervisord",
                    "method": "supervisord",
                    "stop_command": ' '.join(stop_cmd),
                    "start_command": ' '.join(start_cmd),
                    "stop_output": stop_result.stdout,
                    "start_output": start_result.stdout,
                    "stop_error": stop_result.stderr,
                    "start_error": start_result.stderr,
                    "stop_exit_code": stop_result.returncode,
                    "start_exit_code": start_result.returncode,
                    "timestamp": datetime.now().isoformat()
                }

        except Exception as e:
            logger.error(f"Error restarting with supervisord: {e}")
            return {
                "success": False,
                "message": f"Failed to restart robot controller with supervisord: {str(e)}",
                "method": "supervisord",
                "error": str(e),
                "timestamp": datetime.now().isoformat()
            }

    def _restart_with_direct_method(self) -> Dict[str, Any]:
        """Restart the robot controller using the direct method (original implementation)"""
        try:
            logger.info("Using direct method to restart robot controller")

            # First validate that required files exist
            validation = self.validate_controller_files()
            if not validation["valid"]:
                return {
                    "success": False,
                    "message": "Validation failed",
                    "error": validation["error"],
                    "timestamp": datetime.now().isoformat()
                }

            # Kill any existing PhantomControllerRunner processes
            try:
                subprocess.run(['pkill', '-f', 'PhantomControllerRunner'],
                             capture_output=True, text=True, check=False)
                time.sleep(1)  # Give processes time to terminate
            except Exception as e:
                logger.warning(f"Error killing existing processes: {e}")

            # Start the PhantomControllerRunner
            cmd = [
                self.runner_path,
                '-i', self.interface,
                '-p', self.json_file
            ]

            logger.info(f"Starting robot controller: {' '.join(cmd)}")

            # Start the process in the background
            process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True
            )

            # Wait a moment to see if it starts successfully
            time.sleep(2)

            # Check if the process is still running
            if process.poll() is None:
                return {
                    "success": True,
                    "message": "Robot controller restarted successfully using direct method",
                    "method": "direct",
                    "command": ' '.join(cmd),
                    "pid": process.pid,
                    "controller_path": self.runner_path,
                    "json_file": self.json_file,
                    "interface": self.interface,
                    "timestamp": datetime.now().isoformat()
                }
            else:
                # Process exited, get error output
                stdout, stderr = process.communicate()
                return {
                    "success": False,
                    "message": "Robot controller failed to start using direct method",
                    "method": "direct",
                    "command": ' '.join(cmd),
                    "stdout": stdout,
                    "stderr": stderr,
                    "exit_code": process.returncode,
                    "timestamp": datetime.now().isoformat()
                }

        except Exception as e:
            logger.error(f"Error restarting with direct method: {e}")
            return {
                "success": False,
                "message": f"Failed to restart robot controller with direct method: {str(e)}",
                "method": "direct",
                "error": str(e),
                "timestamp": datetime.now().isoformat()
            }

    def get_robot_logs(self, lines: int = 100) -> Dict[str, Any]:
        """Get robot controller logs"""
        try:
            # Try to get logs from journalctl if the process is running as a service
            try:
                # First try to find the process by name
                result = subprocess.run(
                    ['pgrep', '-f', 'PhantomControllerRunner'],
                    capture_output=True,
                    text=True,
                    check=False
                )

                if result.returncode == 0 and result.stdout.strip():
                    # Process is running, try to get logs from journalctl
                    pid = result.stdout.strip().split('\n')[0]
                    result = subprocess.run(
                        ['journalctl', '-p', 'info', '-n', str(lines), '--no-pager', f'_PID={pid}'],
                        capture_output=True,
                        text=True,
                        check=False
                    )

                    if result.returncode == 0 and result.stdout.strip():
                        logs = result.stdout.strip().split('\n')
                        return {
                            "source": "journalctl",
                            "lines": len(logs),
                            "logs": logs,
                            "pid": pid,
                            "timestamp": datetime.now().isoformat()
                        }

                # If journalctl doesn't work, try to get logs from the process directly
                # This is a fallback method
                return {
                    "source": "process_check",
                    "lines": 0,
                    "logs": [f"Robot controller process found (PID: {result.stdout.strip()}) but no logs available"],
                    "message": "Robot controller is running but logs are not accessible via journalctl",
                    "timestamp": datetime.now().isoformat()
                }

            except subprocess.CalledProcessError:
                # Process not found, return appropriate message
                return {
                    "source": "process_check",
                    "lines": 0,
                    "logs": ["Robot controller process not found"],
                    "message": "Robot controller is not currently running",
                    "timestamp": datetime.now().isoformat()
                }

        except Exception as e:
            logger.error(f"Error getting robot logs: {e}")
            return {
                "source": "error",
                "lines": 0,
                "logs": [],
                "error": str(e),
                "message": f"Failed to get robot logs: {str(e)}",
                "timestamp": datetime.now().isoformat()
            }


class RecordingControlManager:
    """Manages recording control via ROS2 topics in Docker containers"""

    @staticmethod
    def execute_command_in_container(container_name: str, command: str, docker_command: str = "docker", timeout: int = 10) -> Dict[str, Any]:
        """
        Execute a command inside a Docker container

        Args:
            container_name: Name of the Docker container
            command: Command to execute
            docker_command: Path to docker executable (default: "docker")
            timeout: Command timeout in seconds (default: 10)

        Returns:
            Dictionary with execution result
        """
        try:
            # Check if the container is running
            result = subprocess.run(
                [docker_command, 'ps', '--filter', f'name={container_name}', '--format', '{{.Names}}'],
                capture_output=True,
                text=True,
                check=False
            )

            if result.returncode != 0:
                logger.error(f"Error checking container status: {result.stderr}")
                return {
                    "success": False,
                    "message": "Failed to check container status",
                    "container_name": container_name,
                    "error": result.stderr.strip(),
                    "timestamp": datetime.now().isoformat()
                }

            # Check if the container is in the output
            running_containers = result.stdout.strip().split('\n')
            if container_name not in running_containers:
                logger.warning(f"Container {container_name} is not running")
                return {
                    "success": False,
                    "message": f"positronic-control system service is not running (container {container_name} not found)",
                    "container_name": container_name,
                    "error": "Container not running",
                    "timestamp": datetime.now().isoformat()
                }

            # Container is running, execute the command inside it
            logger.info(f"Executing command in container {container_name}: {command}")

            result = subprocess.run(
                [docker_command, 'exec', container_name, 'bash', '-c', command],
                capture_output=True,
                text=True,
                check=False,
                timeout=timeout
            )

            if result.returncode == 0:
                logger.info(f"Successfully executed command in container {container_name}")
                return {
                    "success": True,
                    "message": "Command executed successfully",
                    "container_name": container_name,
                    "command": command,
                    "output": result.stdout.strip() if result.stdout else "Command executed successfully",
                    "timestamp": datetime.now().isoformat()
                }
            else:
                logger.error(f"Failed to execute command in container {container_name}: {result.stderr}")
                return {
                    "success": False,
                    "message": "Failed to execute command",
                    "container_name": container_name,
                    "command": command,
                    "output": result.stdout.strip() if result.stdout else None,
                    "error": result.stderr.strip() if result.stderr else "Command failed",
                    "timestamp": datetime.now().isoformat()
                }

        except subprocess.TimeoutExpired:
            logger.error(f"Command timed out in container {container_name}")
            return {
                "success": False,
                "message": "Command execution timed out",
                "container_name": container_name,
                "command": command,
                "error": f"Timeout after {timeout} seconds",
                "timestamp": datetime.now().isoformat()
            }
        except Exception as e:
            logger.error(f"Unexpected error executing command in container {container_name}: {e}")
            return {
                "success": False,
                "message": f"Unexpected error: {str(e)}",
                "container_name": container_name,
                "command": command,
                "error": str(e),
                "timestamp": datetime.now().isoformat()
            }


class UnifiedServiceManager(ServiceManager):
    """Unified service manager that routes restart requests to appropriate handlers

    Extends ServiceManager to provide a complete interface for all service operations:
    - get_service_status() - Get service status (inherited)
    - get_service_logs() - Get service logs (inherited)
    - restart_service() - Restart a service
    - stop_service() - Stop a service
    """

    # Define valid services and their restart methods
    VALID_SERVICES = {
        'positronic_control': 'AI',
        'rerun': 'AI',
        'ros2-message-tracker': 'AI',
        'locomotion_container': 'AI',
        'locomotion_policy': 'AI',
        'locomotion_joystick': 'AI',
        'PhantomControllerRunner': 'AI',
        'ethernet-online': 'AI',
        'hardware_testing': 'ROBOT',
        'amr_testbed': 'ROBOT',
        'lift_testbed': 'ROBOT',
        'robot': 'ROBOT',
        # EtherCAT motor master (host systemd) + its spine bridges
        'dma-ethercat': 'ROBOT',
        'dma-boundary-bridge': 'ROBOT',
        'dma-loop-event-bridge': 'ROBOT'
    }

    # Mapping from friendly names to actual systemd service names
    # This will be populated during initialization
    SERVICE_NAME_MAP = {}

    def __init__(
        self,
        service_name: str,
        robot_controller_manager: Optional[RobotControllerManager] = None,
        service_name_map: Optional[Dict[str, str]] = None
    ):
        """
        Initialize UnifiedServiceManager

        Args:
            service_name: Name of the primary systemd service (e.g., phantom-positronic-control.service)
            robot_controller_manager: Optional RobotControllerManager instance for robot operations
            service_name_map: Optional mapping from friendly names to systemd service names
        """
        super().__init__(service_name)
        self.robot_controller_manager = robot_controller_manager

        # Set up service name mapping
        if service_name_map:
            UnifiedServiceManager.SERVICE_NAME_MAP = service_name_map

    @staticmethod
    def validate_service_name(service_name: str) -> bool:
        """Check if service name is valid"""
        return service_name in UnifiedServiceManager.VALID_SERVICES

    @staticmethod
    def get_valid_services() -> List[str]:
        """Get list of valid service names"""
        return list(UnifiedServiceManager.VALID_SERVICES.keys())

    @staticmethod
    def map_to_systemd_name(friendly_name: str) -> str:
        """
        Map a friendly service name to its actual systemd service name

        Args:
            friendly_name: Friendly name (e.g., 'positronic_control', 'rerun')

        Returns:
            Systemd service name (e.g., 'phantom-positronic-control.service')
        """
        return UnifiedServiceManager.SERVICE_NAME_MAP.get(friendly_name, friendly_name)

    @staticmethod
    def get_systemd_service_status(service_name: str) -> Dict[str, Any]:
        """
        Get status for a specific systemd service

        Args:
            service_name: Name of the systemd service

        Returns:
            Dictionary with service status details
        """
        try:
            result = subprocess.run(
                ['systemctl', 'is-active', service_name],
                capture_output=True,
                text=True,
                check=False
            )
            is_active = result.stdout.strip() == 'active'

            # Get detailed status
            result = subprocess.run(
                ['systemctl', 'show', service_name, '--property=ActiveState,SubState,LoadState'],
                capture_output=True,
                text=True,
                check=False
            )

            status_info = {}
            for line in result.stdout.strip().split('\n'):
                if '=' in line:
                    key, value = line.split('=', 1)
                    status_info[key] = value

            return {
                "name": service_name,
                "is_active": is_active,
                "status": result.stdout.strip(),
                "details": status_info,
                "timestamp": datetime.now().isoformat(),
                "statename": "RUNNING" if is_active else "STOPPED"
            }
        except Exception as e:
            logger.error(f"Error getting service status for {service_name}: {e}")
            return {
                "name": service_name,
                "is_active": False,
                "status": "error",
                "error": str(e),
                "timestamp": datetime.now().isoformat(),
                "statename": "STOPPED"
            }

    @staticmethod
    def get_multiple_services_status(service_names: List[str]) -> List[Dict[str, Any]]:
        """
        Get status for multiple systemd services

        Args:
            service_names: List of systemd service names

        Returns:
            List of dictionaries with service status details
        """
        statuses = []
        for service_name in service_names:
            statuses.append(UnifiedServiceManager.get_systemd_service_status(service_name))
        return statuses

    @staticmethod
    def get_service_logs_by_name(service_name: str, lines: int = 100) -> Dict[str, Any]:
        """
        Get logs for a specific AI service by friendly name

        Args:
            service_name: Friendly service name (e.g., 'positronic_control', 'rerun', 'locomotion_policy')
            lines: Number of log lines to return (default: 100, max: 1000)

        Returns:
            Dictionary with service logs
        """
        # Validate service name
        if not UnifiedServiceManager.validate_service_name(service_name):
            return {
                "service_name": service_name,
                "lines": 0,
                "logs": [],
                "error": f"Invalid service name: {service_name}",
                "valid_services": UnifiedServiceManager.get_valid_services(),
                "timestamp": datetime.now().isoformat()
            }

        # Check if it's an AI service
        service_type = UnifiedServiceManager.VALID_SERVICES.get(service_name)
        if service_type != 'AI':
            return {
                "service_name": service_name,
                "lines": 0,
                "logs": [],
                "error": f"Logs are only available for AI services. {service_name} is a {service_type} service.",
                "timestamp": datetime.now().isoformat()
            }

        # Limit lines to prevent memory issues
        if lines > 1000:
            lines = 1000

        # Map friendly name to systemd service name
        systemd_service_name = UnifiedServiceManager.map_to_systemd_name(service_name)

        try:
            result = subprocess.run(
                ['journalctl', '-u', systemd_service_name, '-n', str(lines), '--no-pager'],
                capture_output=True,
                text=True,
                check=True
            )

            logs = result.stdout.strip().split('\n')

            return {
                "service_name": service_name,
                "systemd_service_name": systemd_service_name,
                "lines": len(logs),
                "logs": logs,
                "timestamp": datetime.now().isoformat()
            }
        except subprocess.CalledProcessError as e:
            logger.error(f"Error getting service logs for {service_name}: {e}")
            return {
                "service_name": service_name,
                "systemd_service_name": systemd_service_name,
                "lines": 0,
                "logs": [],
                "error": str(e),
                "timestamp": datetime.now().isoformat()
            }
        except Exception as e:
            logger.error(f"Unexpected error getting service logs for {service_name}: {e}")
            return {
                "service_name": service_name,
                "systemd_service_name": systemd_service_name,
                "lines": 0,
                "logs": [],
                "error": str(e),
                "timestamp": datetime.now().isoformat()
            }

    def restart_service(self, service_name: str, command: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """
        Route service restart to appropriate handler based on service name

        Args:
            service_name: Name of the service to restart
            command: Optional parameter overrides as key-value pairs (for positronic_control and locomotion_policy)

        Returns:
            Dictionary with restart result
        """
        if not service_name:
            service_name = self.service_name

        if not UnifiedServiceManager.validate_service_name(service_name):
            return {
                "success": False,
                "service_name": service_name,
                "message": f"Invalid service name: {service_name}",
                "valid_services": UnifiedServiceManager.get_valid_services(),
                "timestamp": datetime.now().isoformat()
            }

        unit_type = UnifiedServiceManager.VALID_SERVICES[service_name]

        try:
            if unit_type == 'AI':
                if service_name == 'positronic_control':
                    return self._restart_positronic_control(command)
                elif service_name == 'locomotion_policy':
                    return self._restart_locomotion_policy(command)
                else:
                    # For other AI services (rerun, ros2-message-tracker, locomotion_container, locomotion_joystick), use generic systemd restart
                    return self._restart_systemd_service(UnifiedServiceManager.map_to_systemd_name(service_name))
            elif unit_type == 'ROBOT':
                return self._restart_supervisord_specific(service_name)
            else:
                return {
                    "success": False,
                    "service_name": service_name,
                    "message": f"service {service_name} is not supported",
                    "timestamp": datetime.now().isoformat()
                }
        except Exception as e:
            logger.error(f"Error restarting service {service_name}: {e}")
            return {
                "success": False,
                "service_name": service_name,
                "message": f"Failed to restart service: {str(e)}",
                "error": str(e),
                "timestamp": datetime.now().isoformat()
            }


    def _restart_positronic_control(self, params: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """
        Restart positronic_control service by setting ROS2 command via systemd PHANTOM_CMD override.

        This method creates a systemd override file that sets the PHANTOM_CMD environment
        variable, then restarts the service. The startup script will use this variable
        to override the default Docker command.

        Args:
            params: Optional parameter overrides as key-value pairs
                {
                  "command": string, # default ros2 launch srg_localization global_positioning_launch.py
                  "params": {key: value, ...} # key-value pairs to override default params
                }

        Returns:
            Dictionary with restart result
        """
        try:
            logger.info(f"Restarting positronic_control service using environment variable method")

            # Use /run/systemd/system for runtime overrides (writable on NixOS)
            override_dir = f"/run/systemd/system/{self.service_name}.d"
            override_file = f"{override_dir}/ros2-command-override.conf"

            if params is not None:
                default_params = {
                    "command": "ros2 launch srg_localization global_positioning_launch.py",
                    "params" : {
                        "location": "production",
                    },
                }

                # Merge user params with defaults (user params override defaults)
                # Merge 'command' and nested 'params' separately
                merged_params = default_params.copy()
                # Merge 'command'
                if "command" in params:
                    merged_params["command"] = params["command"]
                # Merge nested 'params' dicts
                merged_params["params"] = {**default_params.get("params", {}), **params.get("params", {})}

                ros2_command = merged_params.get("command", "ros2 launch srg_localization global_positioning_launch.py")

                # Construct parameter string
                param_string = " ".join([f"{key}:={value}" for key, value in merged_params.get("params", {}).items()])

                # Construct full ROS2 command
                full_command = f"{ros2_command} {param_string}"

                logger.info(f"Setting PHANTOM_CMD via systemd override: {full_command}")
                logger.info(f"User provided params: {params}")
                logger.info(f"Merged params: {merged_params}")

                # Create override directory if it doesn't exist
                os.makedirs(override_dir, exist_ok=True)

                # Create override configuration
                override_content = f"""[Service]
Environment="PHANTOM_CMD={full_command}"
"""

                # Write override file
                with open(override_file, 'w') as f:
                    f.write(override_content)

                logger.info(f"Created systemd override at {override_file}")
            else:
                # No params provided, remove override file if it exists
                if os.path.exists(override_file):
                    os.remove(override_file)
                    logger.info(f"Removed systemd override file: {override_file}")

            # Reload systemd to pick up the changes
            subprocess.run(
                ['systemctl', 'daemon-reload'],
                capture_output=True,
                text=True,
                check=True
            )
            logger.info("Systemd daemon reloaded")

            # Use the generic systemd restart method to restart the service
            restart_result = self._restart_systemd_service(self.service_name)

            # If restart failed, return the error
            if not restart_result.get("success"):
                restart_result["method"] = "systemd_envvar"  # Override method name
                return restart_result

            # Get detailed status for positronic_control
            status = self.get_service_status()

            # Build response with detailed status
            return {
                "success": True,
                "service_name": "positronic_control",
                "message": "Service positronic_control restarted successfully using environment variable method",
                "method": "systemd_envvar",
                "status": status,
                "is_active": restart_result.get("is_active"),
                "timestamp": datetime.now().isoformat()
            }

        except subprocess.CalledProcessError as e:
            logger.error(f"Error restarting positronic_control with envvar method: {e}")
            return {
                "success": False,
                "service_name": "positronic_control",
                "message": f"Failed to restart service: {e.stderr}",
                "method": "systemd_envvar",
                "error": str(e),
                "timestamp": datetime.now().isoformat()
            }
        except Exception as e:
            logger.error(f"Unexpected error restarting positronic_control with envvar method: {e}")
            return {
                "success": False,
                "service_name": "positronic_control",
                "message": f"Unexpected error: {str(e)}",
                "method": "systemd_envvar",
                "error": str(e),
                "timestamp": datetime.now().isoformat()
            }

    def _restart_locomotion_policy(self, params: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """
        Restart locomotion_policy service by setting environment variables via systemd override.

        This method creates a systemd override file that sets the environment variables
        for STANDING_POLICY, WALKING_POLICY, and ROS_DOMAIN_ID, then restarts the service.

        Args:
            params: Optional parameter overrides as key-value pairs
                {
                  "STANDING_POLICY": string,  # default "2025-09-22_12-29-04"
                  "WALKING_POLICY": string,   # default "2025-10-09_09-12-30-latency"
                  "ROS_DOMAIN_ID": string     # default "103"
                }

        Returns:
            Dictionary with restart result
        """
        try:
            logger.info(f"Restarting locomotion_policy service using environment variable method")

            # Map locomotion_policy to its systemd service name
            systemd_service_name = UnifiedServiceManager.map_to_systemd_name('locomotion_policy')

            # Use /run/systemd/system for runtime overrides (writable on NixOS)
            override_dir = f"/run/systemd/system/{systemd_service_name}.d"
            override_file = f"{override_dir}/locomotion-params-override.conf"

            if params is not None:
                default_params = {
                    "STANDING_POLICY": "2025-09-22_12-29-04",
                    "WALKING_POLICY": "2025-10-09_09-12-30-latency",
                    "ROS_DOMAIN_ID": "103"
                }

                # Merge user params with defaults (user params override defaults)
                merged_params = {**default_params, **params}

                logger.info(f"User provided params: {params}")
                logger.info(f"Merged params: {merged_params}")

                # Create override directory if it doesn't exist
                os.makedirs(override_dir, exist_ok=True)

                # Create override configuration with environment variables
                env_lines = [f'Environment="{key}={value}"' for key, value in merged_params.items()]
                override_content = f"""[Service]
{chr(10).join(env_lines)}
"""

                # Write override file
                with open(override_file, 'w') as f:
                    f.write(override_content)

                logger.info(f"Created systemd override at {override_file}")
            else:
                # No params provided, remove override file if it exists
                if os.path.exists(override_file):
                    os.remove(override_file)
                    logger.info(f"Removed systemd override file: {override_file}")

            # Reload systemd to pick up the changes
            subprocess.run(
                ['systemctl', 'daemon-reload'],
                capture_output=True,
                text=True,
                check=True
            )
            logger.info("Systemd daemon reloaded")

            # Use the generic systemd restart method to restart the service
            restart_result = self._restart_systemd_service(systemd_service_name)

            # If restart failed, return the error
            if not restart_result.get("success"):
                restart_result["method"] = "systemd_envvar"  # Override method name
                return restart_result

            # Build response with detailed status
            return {
                "success": True,
                "service_name": "locomotion_policy",
                "message": "Service locomotion_policy restarted successfully using environment variable method",
                "method": "systemd_envvar",
                "is_active": restart_result.get("is_active"),
                "timestamp": datetime.now().isoformat()
            }

        except subprocess.CalledProcessError as e:
            logger.error(f"Error restarting locomotion_policy with envvar method: {e}")
            return {
                "success": False,
                "service_name": "locomotion_policy",
                "message": f"Failed to restart service: {e.stderr}",
                "method": "systemd_envvar",
                "error": str(e),
                "timestamp": datetime.now().isoformat()
            }
        except Exception as e:
            logger.error(f"Unexpected error restarting locomotion_policy with envvar method: {e}")
            return {
                "success": False,
                "service_name": "locomotion_policy",
                "message": f"Unexpected error: {str(e)}",
                "method": "systemd_envvar",
                "error": str(e),
                "timestamp": datetime.now().isoformat()
            }

    @staticmethod
    def _restart_systemd_service(service_name: str) -> Dict[str, Any]:
        """
        Restart a generic systemd service (for rerun, ros2-message-tracker, etc.)

        Args:
            service_name: Name of the systemd service to restart

        Returns:
            Dictionary with restart result
        """
        try:
            logger.info(f"Restarting systemd service: {service_name}")

            # Restart the service
            result = subprocess.run(
                ['systemctl', 'restart', service_name],
                capture_output=True,
                text=True,
                check=True
            )

            logger.info(f"Systemd service {service_name} restarted successfully")

            # Wait a moment and check status
            time.sleep(2)

            # Get service status
            status_result = subprocess.run(
                ['systemctl', 'is-active', service_name],
                capture_output=True,
                text=True,
                check=False
            )
            is_active = status_result.stdout.strip() == 'active'

            return {
                "success": True,
                "service_name": service_name,
                "message": f"Service {service_name} restarted successfully",
                "method": "systemd",
                "is_active": is_active,
                "timestamp": datetime.now().isoformat()
            }

        except subprocess.CalledProcessError as e:
            logger.error(f"Error restarting systemd service {service_name}: {e}")
            return {
                "success": False,
                "service_name": service_name,
                "message": f"Failed to restart service: {e.stderr}",
                "method": "systemd",
                "error": str(e),
                "timestamp": datetime.now().isoformat()
            }
        except Exception as e:
            logger.error(f"Unexpected error restarting systemd service {service_name}: {e}")
            return {
                "success": False,
                "service_name": service_name,
                "message": f"Unexpected error: {str(e)}",
                "method": "systemd",
                "error": str(e),
                "timestamp": datetime.now().isoformat()
            }

    @staticmethod
    def _restart_supervisord_specific(service_name: str) -> Dict[str, Any]:
        """
        Restart a specific supervisord service

        Args:
            service_name: Name of the service (e.g., 'PhantomControllerRunner')
        """
        if service_name == 'robot':
            service_name = '*'
        try:
            logger.info(f"Restarting supervisord service: phantom_apps:{service_name}")

            supervisord_service = f"phantom_apps:{service_name}"

            # Stop the service
            restart_cmd = ['supervisorctl', 'restart', supervisord_service]
            logger.info(f"Restarting service: {' '.join(restart_cmd)}")

            restart_result = subprocess.run(
                restart_cmd,
                capture_output=True,
                text=True,
                check=False
            )

            if restart_result.returncode == 0:
                return {
                    "success": True,
                    "service_name": service_name,
                    "message": f"Service {service_name} restarted successfully",
                    "restart_output": restart_result.stdout.strip(),
                    "timestamp": datetime.now().isoformat()
                }
            else:
                return {
                    "success": False,
                    "service_name": service_name,
                    "message": f"Failed to restart service {service_name}",
                    "restart_output": restart_result.stdout.strip(),
                    "restart_error": restart_result.stderr.strip(),
                    "timestamp": datetime.now().isoformat()
                }

        except Exception as e:
            logger.error(f"Error restarting supervisord service {service_name}: {e}")
            return {
                "success": False,
                "service_name": service_name,
                "message": f"Failed to restart service {service_name}: {str(e)}",
                "error": str(e),
                "timestamp": datetime.now().isoformat()
            }

    def stop_service(self, service_name: str) -> Dict[str, Any]:
        """
        Route service stop to appropriate handler based on service name

        Args:
            service_name: Name of the service to stop

        Returns:
            Dictionary with stop result
        """
        if not service_name:
            service_name = self.service_name

        if not UnifiedServiceManager.validate_service_name(service_name):
            return {
                "success": False,
                "service_name": service_name,
                "message": f"Invalid service name: {service_name}",
                "valid_services": UnifiedServiceManager.get_valid_services(),
                "timestamp": datetime.now().isoformat()
            }

        unit_type = UnifiedServiceManager.VALID_SERVICES[service_name]

        try:
            if unit_type == 'AI':
                if service_name == 'positronic_control':
                    return self._stop_positronic_control()
                else:
                    # For other AI services (rerun, ros2-message-tracker, locomotion_*, PhantomControllerRunner), use generic systemd stop
                    return self._stop_systemd_service(UnifiedServiceManager.map_to_systemd_name(service_name))
            elif unit_type == 'ROBOT':
                return self._stop_supervisord_specific(service_name)
            else:
                return {
                    "success": False,
                    "service_name": service_name,
                    "message": f"service {service_name} is not supported",
                    "timestamp": datetime.now().isoformat()
                }
        except Exception as e:
            logger.error(f"Error stopping service {service_name}: {e}")
            return {
                "success": False,
                "service_name": service_name,
                "message": f"Failed to stop service: {str(e)}",
                "error": str(e),
                "timestamp": datetime.now().isoformat()
            }

    def _stop_positronic_control(self) -> Dict[str, Any]:
        """
        Stop positronic_control service using systemctl
        """
        try:
            logger.info(f"Stopping positronic_control service")

            # Use the generic systemd stop method
            stop_result = self._stop_systemd_service(self.service_name)

            # If stop failed, return the error
            if not stop_result.get("success"):
                return stop_result

            # Get detailed status for positronic_control
            status = self.get_service_status()

            # Build response with detailed status
            return {
                "success": True,
                "service_name": "positronic_control",
                "message": f"Service {self.service_name} stopped successfully",
                "status": status,
                "is_active": stop_result.get("is_active"),
                "timestamp": datetime.now().isoformat()
            }

        except Exception as e:
            logger.error(f"Error stopping positronic_control service: {e}")
            return {
                "success": False,
                "service_name": "positronic_control",
                "message": f"Failed to stop positronic_control service: {str(e)}",
                "error": str(e),
                "timestamp": datetime.now().isoformat()
            }

    @staticmethod
    def _stop_systemd_service(service_name: str) -> Dict[str, Any]:
        """
        Stop a generic systemd service (for rerun, ros2-message-tracker, etc.)

        Args:
            service_name: Name of the systemd service to stop

        Returns:
            Dictionary with stop result
        """
        try:
            logger.info(f"Stopping systemd service: {service_name}")

            # Stop the service
            result = subprocess.run(
                ['systemctl', 'stop', service_name],
                capture_output=True,
                text=True,
                check=True
            )

            logger.info(f"Systemd service {service_name} stopped successfully")

            # Wait a moment and check status
            time.sleep(2)

            # Get service status
            status_result = subprocess.run(
                ['systemctl', 'is-active', service_name],
                capture_output=True,
                text=True,
                check=False
            )
            is_active = status_result.stdout.strip() == 'active'

            return {
                "success": True,
                "service_name": service_name,
                "message": f"Service {service_name} stopped successfully",
                "method": "systemd",
                "is_active": is_active,
                "timestamp": datetime.now().isoformat()
            }

        except subprocess.CalledProcessError as e:
            logger.error(f"Error stopping systemd service {service_name}: {e}")
            return {
                "success": False,
                "service_name": service_name,
                "message": f"Failed to stop service: {e.stderr}",
                "method": "systemd",
                "error": str(e),
                "timestamp": datetime.now().isoformat()
            }
        except Exception as e:
            logger.error(f"Unexpected error stopping systemd service {service_name}: {e}")
            return {
                "success": False,
                "service_name": service_name,
                "message": f"Unexpected error: {str(e)}",
                "method": "systemd",
                "error": str(e),
                "timestamp": datetime.now().isoformat()
            }

    @staticmethod
    def _stop_supervisord_specific(service_name: str) -> Dict[str, Any]:
        """
        Stop a specific supervisord service

        Args:
            service_name: Name of the service (e.g., 'PhantomControllerRunner')
        """
        if service_name == 'robot':
            service_name = '*'
        try:
            logger.info(f"Stopping supervisord service: phantom_apps:{service_name}")

            supervisord_service = f"phantom_apps:{service_name}"

            # Stop the service
            stop_cmd = ['supervisorctl', 'stop', supervisord_service]
            logger.info(f"Stopping service: {' '.join(stop_cmd)}")

            stop_result = subprocess.run(
                stop_cmd,
                capture_output=True,
                text=True,
                check=False
            )

            if stop_result.returncode == 0:
                return {
                    "success": True,
                    "service_name": service_name,
                    "message": f"Service {service_name} stopped successfully",
                    "stop_output": stop_result.stdout.strip(),
                    "timestamp": datetime.now().isoformat()
                }
            else:
                return {
                    "success": False,
                    "service_name": service_name,
                    "message": f"Failed to stop service {service_name}",
                    "stop_output": stop_result.stdout.strip(),
                    "stop_error": stop_result.stderr.strip(),
                    "timestamp": datetime.now().isoformat()
                }

        except Exception as e:
            logger.error(f"Error stopping supervisord service {service_name}: {e}")
            return {
                "success": False,
                "service_name": service_name,
                "message": f"Failed to stop service {service_name}: {str(e)}",
                "error": str(e),
                "timestamp": datetime.now().isoformat()
            }


class PolicyManager:
    """Manages phantom robot policies - discovery, status, and state transitions.

    This class provides functionality to:
    - List available policies from the policies directory
    - Get current policy status from the running container
    - Trigger policy state transitions (OFF -> STARTUP -> CONTROL)
    """

    # Policy state constants (matching policy.py)
    STATE_OFF = "OFF"
    STATE_STARTUP = "STARTUP"
    STATE_CONTROL = "CONTROL"

    # Valid transition actions
    # Note: "control" is removed because the policy automatically transitions
    # from STARTUP to CONTROL after 1 second of stiffness interpolation
    VALID_ACTIONS = ["startup", "off"]

    def __init__(
        self,
        policies_directory: str = None,
        container_name: str = None,
        docker_command: str = None
    ):
        """
        Initialize PolicyManager

        Args:
            policies_directory: Base directory containing policy folders (defaults to RobotConfig.PHANTOM_MODELS)
            container_name: Name of the Docker container running the policy
            docker_command: Path to docker executable
        """
        # Use RobotConfig for defaults
        self.policies_directory = policies_directory or RobotConfig.PHANTOM_MODELS
        self.container_name = container_name or RobotConfig.PHANTOM_CONTAINER_NAME
        self.docker_command = docker_command or RobotConfig.DOCKER_COMMAND

    def is_container_running(self) -> bool:
        """Check if the phantom container is running"""
        try:
            result = subprocess.run(
                [self.docker_command, 'ps', '--filter', f'name={self.container_name}', '--format', '{{.Names}}'],
                capture_output=True,
                text=True,
                check=False
            )
            return self.container_name in result.stdout.strip().split('\n')
        except Exception as e:
            logger.error(f"Error checking container status: {e}")
            return False

    def list_policies(self) -> Dict[str, Any]:
        """
        List all available policies from the models directory.

        Uses RobotConfig.PHANTOM_MODELS for the models directory path.

        Returns:
            Dictionary with list of policy names
        """
        try:
            # Use configured policies directory
            models_path = self.policies_directory

            if not os.path.isdir(models_path):
                return {
                    "success": False,
                    "policies": [],
                    "count": 0,
                    "timestamp": datetime.now().isoformat(),
                    "error": f"Models directory does not exist: {models_path}"
                }

            # List all items in the directory (only directories)
            policies = [
                name for name in os.listdir(models_path)
                if os.path.isdir(os.path.join(models_path, name))
            ]

            return {
                "success": True,
                "policies": sorted(policies),
                "count": len(policies),
                "timestamp": datetime.now().isoformat()
            }

        except Exception as e:
            logger.error(f"Error listing policies: {e}")
            return {
                "success": False,
                "policies": [],
                "count": 0,
                "timestamp": datetime.now().isoformat(),
                "error": str(e)
            }

    def get_policy_status(self) -> Dict[str, Any]:
        """
        Get the current policy status by querying the ROS2 topic

        Returns:
            Dictionary with current policy state and configuration
        """
        try:
            container_running = self.is_container_running()

            if not container_running:
                return {
                    "success": True,
                    "state": self.STATE_OFF,
                    "policy_path": None,
                    "checkpoint_num": None,
                    "teleop_mode": None,
                    "container_running": False,
                    "timestamp": datetime.now().isoformat()
                }

            # Query the policy state from ROS2 topic
            # The policy node publishes state to /phantom/policy_state
            command = 'source /src/workspace/install/setup.bash && ros2 topic echo /phantom/policy_state --once --no-arr 2>/dev/null || echo "TOPIC_NOT_AVAILABLE"'

            result = subprocess.run(
                [self.docker_command, 'exec', self.container_name, 'bash', '-c', command],
                capture_output=True,
                text=True,
                check=False,
                timeout=10
            )

            output = result.stdout.strip()

            # Parse the state from output
            # Policy state is published as an integer: 0=OFF, 1=STARTUP, 2=CONTROL
            state = self.STATE_OFF
            if "TOPIC_NOT_AVAILABLE" not in output and output:
                try:
                    # Try to parse the state value
                    if "data: 0" in output or "'data': 0" in output:
                        state = self.STATE_OFF
                    elif "data: 1" in output or "'data': 1" in output:
                        state = self.STATE_STARTUP
                    elif "data: 2" in output or "'data': 2" in output:
                        state = self.STATE_CONTROL
                except Exception:
                    pass

            return {
                "success": True,
                "state": state,
                "policy_path": None,  # Would need to query from params
                "checkpoint_num": None,
                "teleop_mode": None,
                "container_running": True,
                "timestamp": datetime.now().isoformat()
            }

        except subprocess.TimeoutExpired:
            logger.warning("Timeout getting policy status")
            return {
                "success": False,
                "state": self.STATE_OFF,
                "policy_path": None,
                "checkpoint_num": None,
                "teleop_mode": None,
                "container_running": self.is_container_running(),
                "timestamp": datetime.now().isoformat(),
                "error": "Timeout querying policy state"
            }
        except Exception as e:
            logger.error(f"Error getting policy status: {e}")
            return {
                "success": False,
                "state": self.STATE_OFF,
                "policy_path": None,
                "checkpoint_num": None,
                "teleop_mode": None,
                "container_running": self.is_container_running(),
                "timestamp": datetime.now().isoformat(),
                "error": str(e)
            }

    def transition_policy_state(self, action: str) -> Dict[str, Any]:
        """
        Trigger a policy state transition by publishing to ROS2 topic

        Args:
            action: Transition action - 'startup' or 'off'
                - 'startup': Publishes to /phantom/start_startup (Bool) to trigger
                  OFF -> STARTUP -> CONTROL transition (auto-transitions after 1 second)
                - 'off': Publishes to /phantom/stop_policy (Bool) to trigger
                  any state -> OFF transition with stiffness interpolation

        Returns:
            Dictionary with transition result
        """
        if action not in self.VALID_ACTIONS:
            return {
                "success": False,
                "message": f"Invalid action: {action}. Valid actions: {self.VALID_ACTIONS}",
                "previous_state": None,
                "current_state": self.STATE_OFF,
                "timestamp": datetime.now().isoformat(),
                "error": f"Invalid action: {action}"
            }

        try:
            if not self.is_container_running():
                return {
                    "success": False,
                    "message": "Container is not running. Cannot transition policy state.",
                    "previous_state": self.STATE_OFF,
                    "current_state": self.STATE_OFF,
                    "timestamp": datetime.now().isoformat(),
                    "error": "Container not running"
                }

            # Get current state before transition
            status = self.get_policy_status()
            previous_state = status.get("state", self.STATE_OFF)

            # Map action to ROS2 topic and expected state
            # The policy node in positronic_control uses:
            # - /phantom/start_startup (Bool): triggers OFF -> STARTUP -> CONTROL
            # - /phantom/stop_policy (Bool): triggers any state -> OFF
            if action == "startup":
                topic = "/phantom/start_startup"
                expected_state = self.STATE_STARTUP  # Initially goes to STARTUP, then auto-transitions to CONTROL
            else:  # action == "off"
                topic = "/phantom/stop_policy"
                expected_state = self.STATE_OFF

            # Publish Bool message to the appropriate topic
            command = f'source /src/workspace/install/setup.bash && ros2 topic pub -1 {topic} std_msgs/msg/Bool "{{data: true}}"'

            result = subprocess.run(
                [self.docker_command, 'exec', self.container_name, 'bash', '-c', command],
                capture_output=True,
                text=True,
                check=False,
                timeout=15
            )

            if result.returncode != 0:
                return {
                    "success": False,
                    "message": f"Failed to publish state transition: {result.stderr}",
                    "previous_state": previous_state,
                    "current_state": previous_state,
                    "timestamp": datetime.now().isoformat(),
                    "error": result.stderr
                }

            # Wait a moment for the transition to take effect
            # For startup, we wait a bit longer since it goes through STARTUP first
            wait_time = 1.5 if action == "startup" else 0.5
            time.sleep(wait_time)

            # Get new state after transition
            new_status = self.get_policy_status()
            current_state = new_status.get("state", previous_state)

            # For startup action, success means we're in STARTUP or CONTROL
            # (since auto-transition to CONTROL happens after 1 second)
            if action == "startup":
                success = current_state in [self.STATE_STARTUP, self.STATE_CONTROL]
            else:
                success = current_state == expected_state

            return {
                "success": success,
                "message": f"Policy state transition {'completed' if success else 'requested'}: {previous_state} -> {current_state}",
                "previous_state": previous_state,
                "current_state": current_state,
                "timestamp": datetime.now().isoformat()
            }

        except subprocess.TimeoutExpired:
            logger.warning("Timeout during policy state transition")
            return {
                "success": False,
                "message": "Timeout during state transition",
                "previous_state": previous_state if 'previous_state' in locals() else self.STATE_OFF,
                "current_state": self.STATE_OFF,
                "timestamp": datetime.now().isoformat(),
                "error": "Timeout"
            }
        except Exception as e:
            logger.error(f"Error during policy state transition: {e}")
            return {
                "success": False,
                "message": f"Error during state transition: {str(e)}",
                "previous_state": previous_state if 'previous_state' in locals() else self.STATE_OFF,
                "current_state": self.STATE_OFF,
                "timestamp": datetime.now().isoformat(),
                "error": str(e)
            }

    def get_policy_logs(self, lines: int = 100, follow: bool = False) -> Dict[str, Any]:
        """
        Get logs from the phantom container.

        Args:
            lines: Number of log lines to retrieve (default 100)
            follow: If True, returns streaming generator (for SSE), otherwise returns list

        Returns:
            Dictionary with log lines or error information
        """
        try:
            # Check if container is running
            check_cmd = [self.docker_command, "ps", "-q", "-f", f"name={self.container_name}"]
            result = subprocess.run(check_cmd, capture_output=True, text=True, timeout=5)

            if not result.stdout.strip():
                return {
                    "success": False,
                    "container_name": self.container_name,
                    "container_running": False,
                    "logs": [],
                    "lines": 0,
                    "timestamp": datetime.now().isoformat(),
                    "error": f"Container {self.container_name} is not running"
                }

            # Get logs from container
            log_cmd = [self.docker_command, "logs", "--tail", str(lines), self.container_name]

            result = subprocess.run(
                log_cmd,
                capture_output=True,
                text=True,
                timeout=30
            )

            # Docker logs outputs to stderr for container logs
            log_output = result.stderr if result.stderr else result.stdout
            log_lines = log_output.strip().split('\n') if log_output.strip() else []

            return {
                "success": True,
                "container_name": self.container_name,
                "container_running": True,
                "logs": log_lines,
                "lines": len(log_lines),
                "timestamp": datetime.now().isoformat()
            }

        except subprocess.TimeoutExpired:
            logger.warning("Timeout while fetching policy logs")
            return {
                "success": False,
                "container_name": self.container_name,
                "container_running": False,
                "logs": [],
                "lines": 0,
                "timestamp": datetime.now().isoformat(),
                "error": "Timeout while fetching logs"
            }
        except Exception as e:
            logger.error(f"Error fetching policy logs: {e}")
            return {
                "success": False,
                "container_name": self.container_name,
                "container_running": False,
                "logs": [],
                "lines": 0,
                "timestamp": datetime.now().isoformat(),
                "error": str(e)
            }


class PhantomOrchestrator:
    """Orchestrates the startup and shutdown of the phantom robot system via systemd.

    Manages two systemd services:
    - phantom-controller: Standard mode
    - phantom-controller-shm: Shared memory DDS mode

    The services handle all RT scheduling, CPU pinning, and JVM configuration.
    Only one service can be active at a time.
    """

    # Component name
    COMPONENT_PHANTOM_POLICY = "phantom_policy"

    # Systemd service names
    SERVICE_STANDARD = "phantom-controller"
    SERVICE_SHM = "phantom-controller-shm"

    # Port that the Java policy controller listens on
    POLICY_PORT = 8008

    # Stop timeout (in seconds) - time to wait for systemctl stop
    STOP_TIMEOUT = 30
    STOP_POLL_INTERVAL = 0.5

    def __init__(self, **kwargs):
        """
        Initialize PhantomOrchestrator

        Args:
            **kwargs: Ignored for backwards compatibility
        """
        pass

    def _run_systemctl(self, action: str, service: str, timeout: int = 30) -> subprocess.CompletedProcess:
        """
        Run a systemctl command.

        Args:
            action: systemctl action (start, stop, status, is-active)
            service: service name
            timeout: command timeout in seconds

        Returns:
            CompletedProcess result
        """
        cmd = ['systemctl', action, service]
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)

    def _is_service_active(self, service: str) -> bool:
        """Check if a systemd service is active"""
        try:
            result = self._run_systemctl('is-active', service, timeout=5)
            return result.returncode == 0
        except Exception as e:
            logger.warning(f"Error checking service {service}: {e}")
            return False

    def _get_active_service(self) -> Optional[str]:
        """Get which phantom service is currently active, if any"""
        if self._is_service_active(self.SERVICE_SHM):
            return self.SERVICE_SHM
        elif self._is_service_active(self.SERVICE_STANDARD):
            return self.SERVICE_STANDARD
        return None

    def _get_shm_mode(self) -> bool:
        """Check if SHM mode service is currently active"""
        return self._is_service_active(self.SERVICE_SHM)

    def _is_java_process_running(self) -> Tuple[bool, Optional[int]]:
        """
        Check if PhantomJavaPolicyRunner is running as a process (not via systemd).

        Returns:
            Tuple of (is_running, pid) - pid is None if not running
        """
        try:
            result = subprocess.run(
                ['pgrep', '-f', 'PhantomJavaPolicyRunner'],
                capture_output=True,
                text=True,
                timeout=5
            )
            if result.returncode == 0 and result.stdout.strip():
                # Get the first PID
                pid = int(result.stdout.strip().split('\n')[0])
                return True, pid
            return False, None
        except Exception as e:
            logger.warning(f"Error checking for Java process: {e}")
            return False, None

    def get_status(self) -> Dict[str, Any]:
        """
        Get the current status of the phantom system

        Returns:
            Dictionary with orchestration status
        """
        try:
            active_service = self._get_active_service()
            is_systemd_running = active_service is not None
            shm_mode = active_service == self.SERVICE_SHM

            # Also check for manually started Java process
            is_process_running, process_pid = self._is_java_process_running()
            is_running = is_systemd_running or is_process_running

            # Determine status and source
            if is_systemd_running:
                status = "running"
                source = f"systemd ({active_service})"
            elif is_process_running:
                status = "running"
                source = f"manual (PID {process_pid})"
            else:
                status = "stopped"
                source = None

            components = [
                {
                    "name": self.COMPONENT_PHANTOM_POLICY,
                    "status": status,
                    "service_name": active_service or self.SERVICE_STANDARD,
                    "is_active": is_running,
                    "source": source,
                    "pid": process_pid if is_process_running and not is_systemd_running else None,
                    "error": None
                }
            ]

            return {
                "success": True,
                "phantom_running": is_running,
                "shm_mode": shm_mode,
                "manual_process": is_process_running and not is_systemd_running,
                "components": components,
                "timestamp": datetime.now().isoformat()
            }

        except Exception as e:
            logger.error(f"Error getting phantom status: {e}")
            return {
                "success": False,
                "phantom_running": False,
                "shm_mode": False,
                "components": [],
                "timestamp": datetime.now().isoformat(),
                "error": str(e)
            }

    def start(self, shm_mode: bool = False) -> Dict[str, Any]:
        """
        Start the phantom system via systemd service

        Args:
            shm_mode: If True, start phantom-controller-shm; otherwise start phantom-controller

        Returns:
            Dictionary with orchestration result
        """
        try:
            service = self.SERVICE_SHM if shm_mode else self.SERVICE_STANDARD
            logger.info(f"Starting phantom system via systemd service: {service}")

            # Check if already running via systemd
            active_service = self._get_active_service()
            if active_service:
                current_shm = active_service == self.SERVICE_SHM
                return {
                    "success": False,
                    "message": f"Phantom system is already running ({active_service})",
                    "shm_mode": current_shm,
                    "components": [{
                        "name": self.COMPONENT_PHANTOM_POLICY,
                        "status": "running",
                        "service_name": active_service,
                        "is_active": True,
                        "error": None
                    }],
                    "timestamp": datetime.now().isoformat(),
                    "error": "Already running via systemd"
                }

            # Check if running manually (not via systemd)
            is_process_running, process_pid = self._is_java_process_running()
            if is_process_running:
                return {
                    "success": False,
                    "message": f"Phantom Java process is already running manually (PID {process_pid}). Stop it first with: kill {process_pid}",
                    "shm_mode": False,
                    "components": [{
                        "name": self.COMPONENT_PHANTOM_POLICY,
                        "status": "running",
                        "service_name": "manual",
                        "is_active": True,
                        "pid": process_pid,
                        "error": None
                    }],
                    "timestamp": datetime.now().isoformat(),
                    "error": f"Already running manually (PID {process_pid})"
                }

            # Start the service
            result = self._run_systemctl('start', service, timeout=self.STOP_TIMEOUT)

            if result.returncode != 0:
                error_msg = result.stderr.strip() or f"systemctl start {service} failed"
                logger.error(f"Failed to start {service}: {error_msg}")
                return {
                    "success": False,
                    "message": f"Failed to start phantom: {error_msg}",
                    "shm_mode": shm_mode,
                    "components": [{
                        "name": self.COMPONENT_PHANTOM_POLICY,
                        "status": "error",
                        "service_name": service,
                        "is_active": False,
                        "error": error_msg
                    }],
                    "timestamp": datetime.now().isoformat(),
                    "error": error_msg
                }

            # Verify service is now active
            if not self._is_service_active(service):
                error_msg = "Service started but is not active"
                logger.error(f"{service}: {error_msg}")
                return {
                    "success": False,
                    "message": f"Failed to start phantom: {error_msg}",
                    "shm_mode": shm_mode,
                    "components": [{
                        "name": self.COMPONENT_PHANTOM_POLICY,
                        "status": "error",
                        "service_name": service,
                        "is_active": False,
                        "error": error_msg
                    }],
                    "timestamp": datetime.now().isoformat(),
                    "error": error_msg
                }

            logger.info(f"Phantom system started successfully via {service}")
            return {
                "success": True,
                "message": f"Phantom system started successfully ({service})",
                "shm_mode": shm_mode,
                "components": [{
                    "name": self.COMPONENT_PHANTOM_POLICY,
                    "status": "running",
                    "service_name": service,
                    "is_active": True,
                    "error": None
                }],
                "timestamp": datetime.now().isoformat()
            }

        except Exception as e:
            logger.error(f"Error starting phantom system: {e}")
            return {
                "success": False,
                "message": f"Error starting phantom system: {str(e)}",
                "shm_mode": shm_mode,
                "components": [],
                "timestamp": datetime.now().isoformat(),
                "error": str(e)
            }

    def stop(self) -> Dict[str, Any]:
        """
        Stop the phantom system via systemd.

        Stops whichever service is currently active (phantom-controller or phantom-controller-shm).

        Returns:
            Dictionary with orchestration result
        """
        try:
            logger.info("Stopping phantom system")

            # Find which service is running
            active_service = self._get_active_service()

            if not active_service:
                return {
                    "success": True,
                    "message": "Phantom system is not running",
                    "shm_mode": False,
                    "components": [{
                        "name": self.COMPONENT_PHANTOM_POLICY,
                        "status": "stopped",
                        "service_name": self.SERVICE_STANDARD,
                        "is_active": False,
                        "error": None
                    }],
                    "timestamp": datetime.now().isoformat()
                }

            logger.info(f"Stopping service: {active_service}")
            result = self._run_systemctl('stop', active_service, timeout=self.STOP_TIMEOUT)

            if result.returncode != 0:
                error_msg = result.stderr.strip() or f"systemctl stop {active_service} failed"
                logger.error(f"Failed to stop {active_service}: {error_msg}")
                return {
                    "success": False,
                    "message": f"Failed to stop phantom system: {error_msg}",
                    "shm_mode": active_service == self.SERVICE_SHM,
                    "components": [{
                        "name": self.COMPONENT_PHANTOM_POLICY,
                        "status": "running",
                        "service_name": active_service,
                        "is_active": True,
                        "error": error_msg
                    }],
                    "timestamp": datetime.now().isoformat(),
                    "error": error_msg
                }

            # Verify service is now stopped
            if self._is_service_active(active_service):
                error_msg = "Service stop command succeeded but service is still active"
                logger.error(f"{active_service}: {error_msg}")
                return {
                    "success": False,
                    "message": f"Failed to stop phantom system: {error_msg}",
                    "shm_mode": active_service == self.SERVICE_SHM,
                    "components": [{
                        "name": self.COMPONENT_PHANTOM_POLICY,
                        "status": "running",
                        "service_name": active_service,
                        "is_active": True,
                        "error": error_msg
                    }],
                    "timestamp": datetime.now().isoformat(),
                    "error": error_msg
                }

            logger.info(f"Phantom system stopped successfully ({active_service})")
            return {
                "success": True,
                "message": f"Phantom system stopped successfully ({active_service})",
                "shm_mode": False,
                "components": [{
                    "name": self.COMPONENT_PHANTOM_POLICY,
                    "status": "stopped",
                    "service_name": active_service,
                    "is_active": False,
                    "error": None
                }],
                "timestamp": datetime.now().isoformat()
            }

        except Exception as e:
            logger.error(f"Error stopping phantom system: {e}")
            return {
                "success": False,
                "message": f"Error stopping phantom system: {str(e)}",
                "shm_mode": False,
                "components": [],
                "timestamp": datetime.now().isoformat(),
                "error": str(e)
            }

    def get_logs(self, lines: int = 100, service: str = None) -> Dict[str, Any]:
        """
        Get logs from the phantom controller service via journalctl.

        Args:
            lines: Number of log lines to retrieve (default 100)
            service: Specific service to get logs from (default: active service or standard)

        Returns:
            Dictionary with logs
        """
        try:
            # Determine which service to get logs from
            if service:
                target_service = service
            else:
                active_service = self._get_active_service()
                target_service = active_service or self.SERVICE_STANDARD

            logger.info(f"Fetching logs from {target_service}")

            result = subprocess.run(
                ['journalctl', '-u', target_service, '-n', str(lines), '--no-pager'],
                capture_output=True,
                text=True,
                timeout=30
            )

            log_lines = result.stdout.strip().split('\n') if result.stdout.strip() else []

            return {
                "success": True,
                "service_name": target_service,
                "logs": log_lines,
                "lines": len(log_lines),
                "timestamp": datetime.now().isoformat()
            }

        except Exception as e:
            logger.error(f"Error fetching phantom logs: {e}")
            return {
                "success": False,
                "service_name": service or self.SERVICE_STANDARD,
                "logs": [],
                "lines": 0,
                "timestamp": datetime.now().isoformat(),
                "error": str(e)
            }

    def restart(self, shm_mode: bool = None) -> Dict[str, Any]:
        """
        Restart the phantom system via systemd.

        Stops the currently running service and starts it again.
        If shm_mode is specified, switches to that mode; otherwise keeps the current mode.

        Args:
            shm_mode: If specified, start in that mode after stop; otherwise keep current mode

        Returns:
            Dictionary with orchestration result
        """
        try:
            logger.info("Restarting phantom system")

            # Find which service is running to determine current mode
            active_service = self._get_active_service()

            # Determine which mode to use after restart
            if shm_mode is not None:
                # User specified a mode
                target_shm_mode = shm_mode
            elif active_service:
                # Keep current mode
                target_shm_mode = active_service == self.SERVICE_SHM
            else:
                # Not running, default to standard mode
                target_shm_mode = False

            # Stop if running
            if active_service:
                stop_result = self.stop()
                if not stop_result.get("success"):
                    return {
                        "success": False,
                        "message": f"Failed to stop phantom system during restart: {stop_result.get('error', 'Unknown error')}",
                        "shm_mode": target_shm_mode,
                        "components": stop_result.get("components", []),
                        "timestamp": datetime.now().isoformat(),
                        "error": stop_result.get("error")
                    }

            # Start with target mode
            start_result = self.start(shm_mode=target_shm_mode)

            if start_result.get("success"):
                return {
                    "success": True,
                    "message": f"Phantom system restarted successfully ({self.SERVICE_SHM if target_shm_mode else self.SERVICE_STANDARD})",
                    "shm_mode": target_shm_mode,
                    "components": start_result.get("components", []),
                    "timestamp": datetime.now().isoformat()
                }
            else:
                return {
                    "success": False,
                    "message": f"Failed to start phantom system during restart: {start_result.get('error', 'Unknown error')}",
                    "shm_mode": target_shm_mode,
                    "components": start_result.get("components", []),
                    "timestamp": datetime.now().isoformat(),
                    "error": start_result.get("error")
                }

        except Exception as e:
            logger.error(f"Error restarting phantom system: {e}")
            return {
                "success": False,
                "message": f"Error restarting phantom system: {str(e)}",
                "shm_mode": False,
                "components": [],
                "timestamp": datetime.now().isoformat(),
                "error": str(e)
            }


class JavaControllerOrchestrator:
    """Orchestrates the startup and shutdown of the Java controller system via systemd.

    Manages two systemd services:
    - java-controller: Standard mode
    - java-controller-shm: Shared memory DDS mode

    The services handle all RT scheduling, CPU pinning, and JVM configuration.
    Only one service can be active at a time.
    """

    # Component name
    COMPONENT_JAVA_CONTROLLER = "java_controller"

    # Systemd service names
    SERVICE_STANDARD = "java-controller"
    SERVICE_SHM = "java-controller-shm"

    # Stop timeout (in seconds) - time to wait for systemctl stop
    STOP_TIMEOUT = 30
    STOP_POLL_INTERVAL = 0.5

    def __init__(self, **kwargs):
        """
        Initialize JavaControllerOrchestrator

        Args:
            **kwargs: Ignored for backwards compatibility
        """
        pass

    def _run_systemctl(self, action: str, service: str, timeout: int = 30) -> subprocess.CompletedProcess:
        """
        Run a systemctl command.

        Args:
            action: systemctl action (start, stop, status, is-active)
            service: service name
            timeout: command timeout in seconds

        Returns:
            CompletedProcess result
        """
        cmd = ['systemctl', action, service]
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)

    def _is_service_active(self, service: str) -> bool:
        """Check if a systemd service is active"""
        try:
            result = self._run_systemctl('is-active', service, timeout=5)
            return result.returncode == 0
        except Exception as e:
            logger.warning(f"Error checking service {service}: {e}")
            return False

    def _get_active_service(self) -> Optional[str]:
        """Get which java controller service is currently active, if any"""
        if self._is_service_active(self.SERVICE_SHM):
            return self.SERVICE_SHM
        elif self._is_service_active(self.SERVICE_STANDARD):
            return self.SERVICE_STANDARD
        return None

    def _get_shm_mode(self) -> bool:
        """Check if SHM mode service is currently active"""
        return self._is_service_active(self.SERVICE_SHM)

    def get_status(self) -> Dict[str, Any]:
        """
        Get the current status of the Java controller system

        Returns:
            Dictionary with orchestration status
        """
        try:
            active_service = self._get_active_service()
            is_running = active_service is not None
            shm_mode = active_service == self.SERVICE_SHM

            components = [
                {
                    "name": self.COMPONENT_JAVA_CONTROLLER,
                    "status": "running" if is_running else "stopped",
                    "service_name": active_service or self.SERVICE_STANDARD,
                    "is_active": is_running,
                    "error": None
                }
            ]

            return {
                "success": True,
                "java_controller_running": is_running,
                "shm_mode": shm_mode,
                "components": components,
                "timestamp": datetime.now().isoformat()
            }

        except Exception as e:
            logger.error(f"Error getting Java controller status: {e}")
            return {
                "success": False,
                "java_controller_running": False,
                "shm_mode": False,
                "components": [],
                "timestamp": datetime.now().isoformat(),
                "error": str(e)
            }

    def start(self, shm_mode: bool = False) -> Dict[str, Any]:
        """
        Start the Java controller system via systemd service

        Args:
            shm_mode: If True, start java-controller-shm; otherwise start java-controller

        Returns:
            Dictionary with orchestration result
        """
        try:
            service = self.SERVICE_SHM if shm_mode else self.SERVICE_STANDARD
            logger.info(f"Starting Java controller via systemd service: {service}")

            # Check if already running
            active_service = self._get_active_service()
            if active_service:
                current_shm = active_service == self.SERVICE_SHM
                return {
                    "success": False,
                    "message": f"Java controller is already running ({active_service})",
                    "shm_mode": current_shm,
                    "components": [{
                        "name": self.COMPONENT_JAVA_CONTROLLER,
                        "status": "running",
                        "service_name": active_service,
                        "is_active": True,
                        "error": None
                    }],
                    "timestamp": datetime.now().isoformat(),
                    "error": "Already running"
                }

            # Start the service
            result = self._run_systemctl('start', service, timeout=self.STOP_TIMEOUT)

            if result.returncode != 0:
                error_msg = result.stderr.strip() or f"systemctl start {service} failed"
                logger.error(f"Failed to start {service}: {error_msg}")
                return {
                    "success": False,
                    "message": f"Failed to start Java controller: {error_msg}",
                    "shm_mode": shm_mode,
                    "components": [{
                        "name": self.COMPONENT_JAVA_CONTROLLER,
                        "status": "error",
                        "service_name": service,
                        "is_active": False,
                        "error": error_msg
                    }],
                    "timestamp": datetime.now().isoformat(),
                    "error": error_msg
                }

            # Verify service is now active
            if not self._is_service_active(service):
                error_msg = "Service started but is not active"
                logger.error(f"{service}: {error_msg}")
                return {
                    "success": False,
                    "message": f"Failed to start Java controller: {error_msg}",
                    "shm_mode": shm_mode,
                    "components": [{
                        "name": self.COMPONENT_JAVA_CONTROLLER,
                        "status": "error",
                        "service_name": service,
                        "is_active": False,
                        "error": error_msg
                    }],
                    "timestamp": datetime.now().isoformat(),
                    "error": error_msg
                }

            logger.info(f"Java controller started successfully via {service}")
            return {
                "success": True,
                "message": f"Java controller started successfully ({service})",
                "shm_mode": shm_mode,
                "components": [{
                    "name": self.COMPONENT_JAVA_CONTROLLER,
                    "status": "running",
                    "service_name": service,
                    "is_active": True,
                    "error": None
                }],
                "timestamp": datetime.now().isoformat()
            }

        except Exception as e:
            logger.error(f"Error starting Java controller: {e}")
            return {
                "success": False,
                "message": f"Error starting Java controller: {str(e)}",
                "shm_mode": shm_mode,
                "components": [],
                "timestamp": datetime.now().isoformat(),
                "error": str(e)
            }

    def stop(self) -> Dict[str, Any]:
        """
        Stop the Java controller via systemd.

        Stops whichever service is currently active (java-controller or java-controller-shm).

        Returns:
            Dictionary with orchestration result
        """
        try:
            logger.info("Stopping Java controller")

            # Find which service is running
            active_service = self._get_active_service()

            if not active_service:
                return {
                    "success": True,
                    "message": "Java controller is not running",
                    "shm_mode": False,
                    "components": [{
                        "name": self.COMPONENT_JAVA_CONTROLLER,
                        "status": "stopped",
                        "service_name": self.SERVICE_STANDARD,
                        "is_active": False,
                        "error": None
                    }],
                    "timestamp": datetime.now().isoformat()
                }

            logger.info(f"Stopping service: {active_service}")
            result = self._run_systemctl('stop', active_service, timeout=self.STOP_TIMEOUT)

            if result.returncode != 0:
                error_msg = result.stderr.strip() or f"systemctl stop {active_service} failed"
                logger.error(f"Failed to stop {active_service}: {error_msg}")
                return {
                    "success": False,
                    "message": f"Failed to stop Java controller: {error_msg}",
                    "shm_mode": active_service == self.SERVICE_SHM,
                    "components": [{
                        "name": self.COMPONENT_JAVA_CONTROLLER,
                        "status": "running",
                        "service_name": active_service,
                        "is_active": True,
                        "error": error_msg
                    }],
                    "timestamp": datetime.now().isoformat(),
                    "error": error_msg
                }

            # Verify service is now stopped
            if self._is_service_active(active_service):
                error_msg = "Service stop command succeeded but service is still active"
                logger.error(f"{active_service}: {error_msg}")
                return {
                    "success": False,
                    "message": f"Failed to stop Java controller: {error_msg}",
                    "shm_mode": active_service == self.SERVICE_SHM,
                    "components": [{
                        "name": self.COMPONENT_JAVA_CONTROLLER,
                        "status": "running",
                        "service_name": active_service,
                        "is_active": True,
                        "error": error_msg
                    }],
                    "timestamp": datetime.now().isoformat(),
                    "error": error_msg
                }

            logger.info(f"Java controller stopped successfully ({active_service})")
            return {
                "success": True,
                "message": f"Java controller stopped successfully ({active_service})",
                "shm_mode": False,
                "components": [{
                    "name": self.COMPONENT_JAVA_CONTROLLER,
                    "status": "stopped",
                    "service_name": active_service,
                    "is_active": False,
                    "error": None
                }],
                "timestamp": datetime.now().isoformat()
            }

        except Exception as e:
            logger.error(f"Error stopping Java controller: {e}")
            return {
                "success": False,
                "message": f"Error stopping Java controller: {str(e)}",
                "shm_mode": False,
                "components": [],
                "timestamp": datetime.now().isoformat(),
                "error": str(e)
            }

    def get_logs(self, lines: int = 100, service: str = None) -> Dict[str, Any]:
        """
        Get logs from the Java controller service via journalctl.

        Args:
            lines: Number of log lines to retrieve (default 100)
            service: Specific service to get logs from (default: active service or standard)

        Returns:
            Dictionary with logs
        """
        try:
            # Determine which service to get logs from
            if service:
                target_service = service
            else:
                active_service = self._get_active_service()
                target_service = active_service or self.SERVICE_STANDARD

            logger.info(f"Fetching logs from {target_service}")

            result = subprocess.run(
                ['journalctl', '-u', target_service, '-n', str(lines), '--no-pager'],
                capture_output=True,
                text=True,
                timeout=30
            )

            log_lines = result.stdout.strip().split('\n') if result.stdout.strip() else []

            return {
                "success": True,
                "service_name": target_service,
                "logs": log_lines,
                "lines": len(log_lines),
                "timestamp": datetime.now().isoformat()
            }

        except Exception as e:
            logger.error(f"Error fetching Java controller logs: {e}")
            return {
                "success": False,
                "service_name": service or self.SERVICE_STANDARD,
                "logs": [],
                "lines": 0,
                "timestamp": datetime.now().isoformat(),
                "error": str(e)
            }

    def restart(self, shm_mode: bool = None) -> Dict[str, Any]:
        """
        Restart the Java controller via systemd.

        Stops the currently running service and starts it again.
        If shm_mode is specified, switches to that mode; otherwise keeps the current mode.

        Args:
            shm_mode: If specified, start in that mode after stop; otherwise keep current mode

        Returns:
            Dictionary with orchestration result
        """
        try:
            logger.info("Restarting Java controller")

            # Find which service is running to determine current mode
            active_service = self._get_active_service()

            # Determine which mode to use after restart
            if shm_mode is not None:
                # User specified a mode
                target_shm_mode = shm_mode
            elif active_service:
                # Keep current mode
                target_shm_mode = active_service == self.SERVICE_SHM
            else:
                # Default to standard mode
                target_shm_mode = False

            # Stop if running
            if active_service:
                stop_result = self.stop()
                if not stop_result["success"]:
                    return {
                        "success": False,
                        "message": f"Failed to stop Java controller during restart: {stop_result.get('error', 'Unknown error')}",
                        "shm_mode": active_service == self.SERVICE_SHM,
                        "components": stop_result.get("components", []),
                        "timestamp": datetime.now().isoformat(),
                        "error": stop_result.get("error")
                    }

            # Start with target mode
            start_result = self.start(shm_mode=target_shm_mode)

            if start_result["success"]:
                return {
                    "success": True,
                    "message": f"Java controller restarted successfully ({self.SERVICE_SHM if target_shm_mode else self.SERVICE_STANDARD})",
                    "shm_mode": target_shm_mode,
                    "components": start_result.get("components", []),
                    "timestamp": datetime.now().isoformat()
                }
            else:
                return {
                    "success": False,
                    "message": f"Failed to start Java controller during restart: {start_result.get('error', 'Unknown error')}",
                    "shm_mode": target_shm_mode,
                    "components": start_result.get("components", []),
                    "timestamp": datetime.now().isoformat(),
                    "error": start_result.get("error")
                }

        except Exception as e:
            logger.error(f"Error restarting Java controller: {e}")
            return {
                "success": False,
                "message": f"Error restarting Java controller: {str(e)}",
                "shm_mode": False,
                "components": [],
                "timestamp": datetime.now().isoformat(),
                "error": str(e)
            }
