"""
Response models for the Phantom Control API

This module contains Pydantic models for all API responses to ensure
proper documentation in the OpenAPI/Swagger interface.
"""

from typing import Dict, List, Optional, Any
from pydantic import BaseModel, Field, RootModel


# Service Status Models
class ServiceStatusDetail(BaseModel):
    """Service status details"""
    name: str = Field(..., description="Service name")
    is_active: bool = Field(..., description="Whether the service is active")
    status: str = Field(..., description="Service status")
    details: Optional[Dict[str, str]] = Field(default=None, description="Additional status details")
    timestamp: str = Field(..., description="Timestamp of status check")
    statename: str = Field(..., description="State name (RUNNING/STOPPED)")
    error: Optional[str] = Field(default=None, description="Error message if status check failed")


# Service Operation Models
class ServiceOperationResponse(BaseModel):
    """Response model for service start/stop/restart operations"""
    success: bool = Field(..., description="Whether the operation was successful")
    service_name: Optional[str] = Field(default=None, description="Name of the service")
    message: str = Field(..., description="Operation result message")
    method: Optional[str] = Field(default=None, description="Method used for the operation (systemd, supervisord, etc.)")
    is_active: Optional[bool] = Field(default=None, description="Whether the service is active after the operation")
    status: Optional[List['ServiceStatusDetail']] = Field(default=None, description="Service status after operation")
    timestamp: str = Field(..., description="Timestamp of the operation")
    error: Optional[str] = Field(default=None, description="Error details if operation failed")
    restart_output: Optional[str] = Field(default=None, description="Output from restart command")
    stop_output: Optional[str] = Field(default=None, description="Output from stop command")
    start_output: Optional[str] = Field(default=None, description="Output from start command")
    valid_services: Optional[List[str]] = Field(default=None, description="List of valid service names (if invalid service requested)")

    class Config:
        # Enable forward references for the status field
        from_attributes = True


# Service Logs Models
class ServiceLogsResponse(BaseModel):
    """Response model for service logs endpoint"""
    service_name: Optional[str] = Field(default=None, description="Name of the service")
    source: Optional[str] = Field(default=None, description="Source of logs (journalctl, process_check, etc.)")
    lines: int = Field(..., description="Number of log lines returned")
    logs: List[str] = Field(..., description="Log lines")
    timestamp: str = Field(..., description="Timestamp of log retrieval")
    error: Optional[str] = Field(default=None, description="Error message if log retrieval failed")
    pid: Optional[str] = Field(default=None, description="Process ID if available")
    message: Optional[str] = Field(default=None, description="Additional message about log retrieval")


# System Reboot Models
class SystemRebootResponse(BaseModel):
    """Response model for system reboot endpoint"""
    success: bool = Field(..., description="Whether the reboot was initiated successfully")
    message: str = Field(..., description="Reboot result message")
    method: Optional[str] = Field(default=None, description="Reboot method used")
    timestamp: str = Field(..., description="Timestamp of reboot initiation")
    error: Optional[str] = Field(default=None, description="Error details if reboot failed")


# System Stats Models
class CPUInfo(BaseModel):
    """CPU information"""
    usage_percent: float = Field(..., description="CPU usage percentage")
    count: int = Field(..., description="Number of CPU cores")
    freq: Optional[Dict[str, float]] = Field(default=None, description="CPU frequency information")


class MemoryInfo(BaseModel):
    """Memory information"""
    total: int = Field(..., description="Total memory in bytes")
    available: int = Field(..., description="Available memory in bytes")
    used: int = Field(..., description="Used memory in bytes")
    percentage: float = Field(..., description="Memory usage percentage")
    free: int = Field(..., description="Free memory in bytes")


class DiskInfo(BaseModel):
    """Disk information for a single mount point"""
    device: str = Field(..., description="Device name")
    fstype: str = Field(..., description="Filesystem type")
    total: int = Field(..., description="Total disk space in bytes")
    used: int = Field(..., description="Used disk space in bytes")
    free: int = Field(..., description="Free disk space in bytes")
    percentage: float = Field(..., description="Disk usage percentage")


class CPUTemperatureInfo(BaseModel):
    """CPU temperature information"""
    current: float = Field(..., description="Current average temperature in Celsius")
    high: Optional[float] = Field(default=None, description="High temperature threshold in Celsius")
    cores: List[float] = Field(..., description="Temperature for each core in Celsius")
    label: str = Field(..., description="Sensor label")


class GPUTemperatureInfo(BaseModel):
    """GPU temperature information"""
    index: int = Field(..., description="GPU index")
    name: str = Field(..., description="GPU name")
    temperature: float = Field(..., description="GPU temperature in Celsius")


class TemperatureInfo(BaseModel):
    """Temperature information"""
    cpu: Optional[CPUTemperatureInfo] = Field(default=None, description="CPU temperature information")
    gpu: Optional[List[GPUTemperatureInfo]] = Field(default=None, description="GPU temperature information")


class SystemStatsResponse(BaseModel):
    """Response model for system stats endpoint"""
    timestamp: str = Field(..., description="Timestamp of stats collection")
    cpu: CPUInfo = Field(..., description="CPU information")
    memory: MemoryInfo = Field(..., description="Memory information")
    disk: Dict[str, DiskInfo] = Field(..., description="Disk information for each mount point")
    temperature: TemperatureInfo = Field(..., description="Temperature information")
    uptime: float = Field(..., description="System uptime in seconds")
    history: Optional[List[Dict[str, Any]]] = Field(default=None, description="Historical stats data")


# Health Check Models
class HealthCheckResponse(BaseModel):
    """Response model for health check endpoint"""
    status: str = Field(..., description="Health status (healthy/unhealthy)")
    timestamp: str = Field(..., description="Timestamp of health check")
    service: str = Field(..., description="Service name")
    uptime: float = Field(..., description="System uptime in seconds")


# Config Models
class RobotControllerConfig(BaseModel):
    """Robot controller configuration"""
    runner_path: str = Field(..., description="Path to PhantomControllerRunner")
    json_file: str = Field(..., description="Path to JSON configuration file")
    interface: str = Field(..., description="Network interface for controller")


class ConfigResponse(BaseModel):
    """Response model for config endpoint"""
    dashboard_auto_refresh: int = Field(..., description="Dashboard auto-refresh interval in seconds")
    stats_collection_interval: int = Field(..., description="Stats collection interval in seconds")
    stats_history_size: int = Field(..., description="Number of historical stats to keep")
    service_name: str = Field(..., description="Default service name")
    api_host: str = Field(..., description="API host address")
    api_port: int = Field(..., description="API port number")
    log_level: str = Field(..., description="Logging level")
    robot_controller: Dict[str, str] = Field(..., description="Robot controller configuration")


# API Info Models
class APIInfoResponse(BaseModel):
    """Response model for API info endpoints"""
    name: str = Field(..., description="API name")
    version: str = Field(..., description="API version")
    description: str = Field(..., description="API description")
    endpoints: Dict[str, Dict[str, str]] = Field(..., description="Available endpoints organized by category")


# Recording Control Models
class RecordingOperationResponse(BaseModel):
    """Response model for recording control operations"""
    success: bool = Field(..., description="Whether the operation was successful")
    message: str = Field(..., description="Operation result message")
    container_name: Optional[str] = Field(default=None, description="Name of the container")
    command: Optional[str] = Field(default=None, description="Command executed")
    output: Optional[str] = Field(default=None, description="Command output")
    timestamp: str = Field(..., description="Timestamp of the operation")
    error: Optional[str] = Field(default=None, description="Error details if operation failed")


# Policy Management Models
class PolicyInfo(BaseModel):
    """Information about an available policy"""
    name: str = Field(..., description="Policy name (directory name)")
    path: str = Field(..., description="Full path to policy directory")
    policy_type: Optional[str] = Field(default=None, description="Policy type (velocity, tracking_jointspace, tracking_taskspace)")
    checkpoint_count: int = Field(default=0, description="Number of available checkpoints")
    latest_checkpoint: Optional[int] = Field(default=None, description="Latest checkpoint number")
    has_dvbf: bool = Field(default=False, description="Whether policy has DVBF model")
    created_at: Optional[str] = Field(default=None, description="Policy creation timestamp")


class PolicyListResponse(BaseModel):
    """Response model for listing available policies"""
    success: bool = Field(..., description="Whether the operation was successful")
    policies: List[str] = Field(default=[], description="List of policy/model names from PHANTOM_MODELS directory")
    count: int = Field(default=0, description="Total number of policies")
    timestamp: str = Field(..., description="Timestamp of the response")
    error: Optional[str] = Field(default=None, description="Error details if operation failed")


class PolicyStatusResponse(BaseModel):
    """Response model for policy status"""
    success: bool = Field(..., description="Whether the operation was successful")
    state: str = Field(..., description="Current policy state (OFF, STARTUP, CONTROL)")
    policy_path: Optional[str] = Field(default=None, description="Path to currently loaded policy")
    checkpoint_num: Optional[str] = Field(default=None, description="Current checkpoint number")
    teleop_mode: Optional[str] = Field(default=None, description="Current teleop mode (velocity, jointspace, taskspace)")
    container_running: bool = Field(default=False, description="Whether positronic_phantom container is running")
    timestamp: str = Field(..., description="Timestamp of the status check")
    error: Optional[str] = Field(default=None, description="Error details if operation failed")


class PolicyTransitionRequest(BaseModel):
    """Request model for policy state transitions"""
    action: str = Field(..., description="Transition action: 'startup' (OFF->STARTUP->CONTROL, auto-transitions after 1 second) or 'off' (any->OFF)")


class PolicyTransitionResponse(BaseModel):
    """Response model for policy state transitions"""
    success: bool = Field(..., description="Whether the transition was successful")
    message: str = Field(..., description="Transition result message")
    previous_state: Optional[str] = Field(default=None, description="State before transition")
    current_state: str = Field(..., description="Current state after transition attempt")
    timestamp: str = Field(..., description="Timestamp of the transition")
    error: Optional[str] = Field(default=None, description="Error details if transition failed")


class PolicyRunRequest(BaseModel):
    """Request model for running a policy"""
    policy_name: str = Field(..., description="Name of the policy to run (from /policy/list)")
    teleop: bool = Field(default=False, description="Enable teleop mode (true for teleoperation, false for autonomous)")
    ros_domain_id: int = Field(default=103, description="ROS2 domain ID for network isolation (0-232)", ge=0, le=232)
    rebuild: bool = Field(default=True, description="Run colcon build before launching (set false to skip build for faster restart)")


class PolicyRunResponse(BaseModel):
    """Response model for policy run endpoint"""
    success: bool = Field(..., description="Whether the policy launch was initiated successfully")
    message: str = Field(..., description="Result message")
    policy_name: str = Field(..., description="Name of the policy being run")
    policy_path: str = Field(..., description="Full path to the policy in container")
    teleop: bool = Field(..., description="Whether teleop mode is enabled")
    output: List[str] = Field(default=[], description="Command output lines")
    timestamp: str = Field(..., description="Timestamp of the operation")
    pid: Optional[int] = Field(default=None, description="Process ID of the running policy in container")
    error: Optional[str] = Field(default=None, description="Error details if operation failed")


class PolicyStopRequest(BaseModel):
    """Request model for stopping a policy"""
    pid: Optional[int] = Field(default=None, description="Process ID of the policy to stop (optional - if not provided, kills all policy processes)")


class PolicyStopResponse(BaseModel):
    """Response model for policy stop endpoint"""
    success: bool = Field(..., description="Whether the policy was stopped successfully")
    message: str = Field(..., description="Result message")
    killed_processes: List[str] = Field(default=[], description="List of processes that were killed")
    timestamp: str = Field(..., description="Timestamp of the operation")
    error: Optional[str] = Field(default=None, description="Error details if operation failed")


class PolicyRunningStatusResponse(BaseModel):
    """Response model for policy running status endpoint"""
    success: bool = Field(..., description="Whether the status check was successful")
    status: str = Field(..., description="Current status: idle, starting, building, running, stopped, error")
    step: Optional[str] = Field(default=None, description="Current step description")
    policy_name: Optional[str] = Field(default=None, description="Name of the running policy if detected")
    pid: Optional[int] = Field(default=None, description="Process ID if running")
    timestamp: str = Field(..., description="Timestamp of the status check")
    error: Optional[str] = Field(default=None, description="Error details if status check failed")


class PolicyLogsResponse(BaseModel):
    """Response model for policy logs endpoint"""
    success: bool = Field(..., description="Whether the log retrieval was successful")
    container_name: str = Field(..., description="Name of the container")
    container_running: bool = Field(..., description="Whether the container is currently running")
    logs: List[str] = Field(default=[], description="Log lines from the container")
    lines: int = Field(default=0, description="Number of log lines returned")
    timestamp: str = Field(..., description="Timestamp of log retrieval")
    error: Optional[str] = Field(default=None, description="Error details if log retrieval failed")


# Phantom Orchestration Models
class PhantomComponentStatus(BaseModel):
    """Status of a phantom component"""
    name: str = Field(..., description="Component name")
    status: str = Field(..., description="Component status (running, stopped, starting, error)")
    service_name: Optional[str] = Field(default=None, description="Associated systemd service name")
    is_active: bool = Field(default=False, description="Whether the component is active")
    source: Optional[str] = Field(default=None, description="How the process was started (systemd or manual)")
    pid: Optional[int] = Field(default=None, description="Process ID if running manually")
    error: Optional[str] = Field(default=None, description="Error message if component has issues")


class PhantomOrchestrationStatusResponse(BaseModel):
    """Response model for phantom orchestration status"""
    success: bool = Field(..., description="Whether the status check was successful")
    phantom_running: bool = Field(..., description="Whether phantom system is running (all required components)")
    shm_mode: bool = Field(default=False, description="Whether running in shared memory (SHM) mode")
    manual_process: bool = Field(default=False, description="Whether running as a manual process (not via systemd)")
    components: List[PhantomComponentStatus] = Field(default=[], description="Status of each component")
    timestamp: str = Field(..., description="Timestamp of the status check")
    error: Optional[str] = Field(default=None, description="Error details if status check failed")


class PhantomOrchestrationRequest(BaseModel):
    """Request model for phantom orchestration start"""
    shm: bool = Field(default=False, description="Enable shared memory DDS transport (faster inter-process communication)")


class PhantomOrchestrationResponse(BaseModel):
    """Response model for phantom orchestration operations (start/stop)"""
    success: bool = Field(..., description="Whether the operation was successful")
    message: str = Field(..., description="Operation result message")
    shm_mode: bool = Field(default=False, description="Whether SHM mode is enabled")
    components: List[PhantomComponentStatus] = Field(default=[], description="Status of each component after operation")
    timestamp: str = Field(..., description="Timestamp of the operation")
    error: Optional[str] = Field(default=None, description="Error details if operation failed")


class JavaControllerComponentStatus(BaseModel):
    """Status of a Java controller component"""
    name: str = Field(..., description="Component name")
    status: str = Field(..., description="Component status (running, stopped, error)")
    service_name: str = Field(..., description="Systemd service name")
    is_active: bool = Field(..., description="Whether the service is currently active")
    error: Optional[str] = Field(default=None, description="Error details if component failed")


class JavaControllerStatusResponse(BaseModel):
    """Response model for Java controller orchestration status"""
    success: bool = Field(..., description="Whether the status check was successful")
    java_controller_running: bool = Field(..., description="Whether Java controller is running")
    shm_mode: bool = Field(default=False, description="Whether running in shared memory (SHM) mode")
    components: List[JavaControllerComponentStatus] = Field(default=[], description="Status of each component")
    timestamp: str = Field(..., description="Timestamp of the status check")
    error: Optional[str] = Field(default=None, description="Error details if status check failed")


class JavaControllerRequest(BaseModel):
    """Request model for Java controller orchestration start"""
    shm: bool = Field(default=False, description="Enable shared memory DDS transport (faster inter-process communication)")


class JavaControllerResponse(BaseModel):
    """Response model for Java controller orchestration operations (start/stop)"""
    success: bool = Field(..., description="Whether the operation was successful")
    message: str = Field(..., description="Operation result message")
    shm_mode: bool = Field(default=False, description="Whether SHM mode is enabled")
    components: List[JavaControllerComponentStatus] = Field(default=[], description="Status of each component after operation")
    timestamp: str = Field(..., description="Timestamp of the operation")
    error: Optional[str] = Field(default=None, description="Error details if operation failed")


class SlaveInfoResponse(BaseModel):
    """Response model for EtherCAT slave info endpoint"""
    success: bool = Field(..., description="Whether the command executed successfully")
    output: List[str] = Field(default=[], description="Output lines from run-slaveInfo script")
    timestamp: str = Field(..., description="Timestamp of the operation")
    error: Optional[str] = Field(default=None, description="Error details if operation failed")


class JoystickStatusResponse(BaseModel):
    """Response model for joystick status endpoint"""
    success: bool = Field(..., description="Whether the status check succeeded")
    connected: bool = Field(..., description="Whether Sony joystick is currently connected")
    device_info: Optional[str] = Field(default=None, description="USB device info line from lsusb")
    port: Optional[str] = Field(default=None, description="USB/IP port number if connected")
    timestamp: str = Field(..., description="Timestamp of the status check")
    error: Optional[str] = Field(default=None, description="Error details if status check failed")


class JoystickAttachRequest(BaseModel):
    """Request model for joystick attach endpoint"""
    remote: str = Field(..., description="IP address of the USB/IP server hosting the joystick")
    busid: str = Field(..., description="Bus ID of the joystick to attach (e.g., '1-1')")


class JoystickAttachResponse(BaseModel):
    """Response model for joystick attach endpoint"""
    success: bool = Field(..., description="Whether the joystick was attached and detected")
    message: str = Field(..., description="Result message")
    remote: str = Field(..., description="IP address used")
    busid: str = Field(..., description="Bus ID used")
    port: Optional[str] = Field(default=None, description="Assigned USB/IP port number (use this for detach)")
    joystick_detected: bool = Field(default=False, description="Whether Sony joystick was detected after attachment")
    output: List[str] = Field(default=[], description="Command output lines")
    timestamp: str = Field(..., description="Timestamp of the operation")
    error: Optional[str] = Field(default=None, description="Error details if operation failed")


class JoystickDetachRequest(BaseModel):
    """Request model for joystick detach endpoint"""
    port: str = Field(..., description="Port number to detach (e.g., '00' or '0')")


class JoystickDetachResponse(BaseModel):
    """Response model for joystick detach endpoint"""
    success: bool = Field(..., description="Whether the joystick was detached")
    message: str = Field(..., description="Result message")
    port: str = Field(..., description="Port that was detached")
    output: List[str] = Field(default=[], description="Command output lines")
    timestamp: str = Field(..., description="Timestamp of the operation")
    error: Optional[str] = Field(default=None, description="Error details if operation failed")


# ADB Models
class AdbDevice(BaseModel):
    """ADB device information"""
    serial: str = Field(..., description="Device serial number")
    state: str = Field(..., description="Device state (device, offline, unauthorized, etc.)")


class AdbDevicesResponse(BaseModel):
    """Response model for adb devices endpoint"""
    success: bool = Field(..., description="Whether the command succeeded")
    devices: List[AdbDevice] = Field(default=[], description="List of connected ADB devices")
    raw_output: str = Field(..., description="Raw output from adb devices command")
    timestamp: str = Field(..., description="Timestamp of the check")
    error: Optional[str] = Field(default=None, description="Error details if command failed")


class AdbReverseRequest(BaseModel):
    """Request model for adb reverse endpoint"""
    port: int = Field(..., description="Port number to expose (e.g., 8000)", ge=1, le=65535)
    serial: Optional[str] = Field(default=None, description="Target device serial (optional, uses first device if not specified)")


class AdbReverseResponse(BaseModel):
    """Response model for adb reverse endpoint"""
    success: bool = Field(..., description="Whether the reverse port was set up successfully")
    message: str = Field(..., description="Result message")
    port: int = Field(..., description="Port that was exposed")
    serial: Optional[str] = Field(default=None, description="Device serial used")
    output: str = Field(default="", description="Command output")
    timestamp: str = Field(..., description="Timestamp of the operation")
    error: Optional[str] = Field(default=None, description="Error details if operation failed")


# Docker Models
class DockerContainer(BaseModel):
    """Docker container information"""
    id: str = Field(..., description="Container ID (short)")
    name: str = Field(..., description="Container name")
    image: str = Field(..., description="Image name")
    status: str = Field(..., description="Status string (e.g., 'Up 2 hours')")
    state: str = Field(..., description="Simple state (running, exited, paused, etc.)")
    ports: str = Field(default="", description="Port mappings")
    created: str = Field(..., description="Creation time")


class DockerContainersResponse(BaseModel):
    """Response model for docker containers list endpoint"""
    success: bool = Field(..., description="Whether the command succeeded")
    containers: List[DockerContainer] = Field(default=[], description="List of containers")
    filter: Optional[str] = Field(default=None, description="Name filter applied (if any)")
    include_stopped: bool = Field(default=False, description="Whether stopped containers are included")
    timestamp: str = Field(..., description="Timestamp of the check")
    error: Optional[str] = Field(default=None, description="Error details if command failed")


class DockerOperationRequest(BaseModel):
    """Request model for docker stop/start/restart operations"""
    name: str = Field(..., description="Container name or ID")


class DockerOperationResponse(BaseModel):
    """Response model for docker stop/start/restart operations"""
    success: bool = Field(..., description="Whether the operation succeeded")
    operation: str = Field(..., description="Operation performed (stop, start, restart)")
    container: str = Field(..., description="Container name or ID")
    message: str = Field(..., description="Result message")
    output: str = Field(default="", description="Command output")
    timestamp: str = Field(..., description="Timestamp of the operation")
    error: Optional[str] = Field(default=None, description="Error details if operation failed")


class DockerCpusetRequest(BaseModel):
    """Request model for docker container cpuset endpoint"""
    cpus: str = Field(default="0-14", description="CPU cores to assign (e.g., '0-14', '0,2,4')")


class DockerCpusetResponse(BaseModel):
    """Response model for docker container cpuset status"""
    success: bool = Field(..., description="Whether the query succeeded")
    container: str = Field(..., description="Container name or ID")
    cpuset: str = Field(default="", description="Current cpuset-cpus value (empty if not set)")
    timestamp: str = Field(..., description="Timestamp of the query")
    error: Optional[str] = Field(default=None, description="Error details if query failed")


class DockerLogsRequest(BaseModel):
    """Request model for docker logs endpoint"""
    name: str = Field(..., description="Container name or ID")
    tail: int = Field(default=100, description="Number of lines to return", ge=1, le=10000)


class DockerLogsResponse(BaseModel):
    """Response model for docker logs endpoint"""
    success: bool = Field(..., description="Whether the command succeeded")
    container: str = Field(..., description="Container name or ID")
    logs: List[str] = Field(default=[], description="Log lines")
    lines: int = Field(..., description="Number of lines returned")
    timestamp: str = Field(..., description="Timestamp of the request")
    error: Optional[str] = Field(default=None, description="Error details if command failed")


# Docker Compose Models
class ComposeProjectInfo(BaseModel):
    """Information about a configured Docker Compose project"""
    name: str = Field(..., description="Project alias name")
    path: str = Field(..., description="Path to compose directory")
    file: str = Field(..., description="Compose file name")


class ComposeProjectsResponse(BaseModel):
    """Response model for listing available compose projects"""
    success: bool = Field(..., description="Whether the operation succeeded")
    projects: List[ComposeProjectInfo] = Field(default=[], description="List of configured projects")
    timestamp: str = Field(..., description="Timestamp of the response")


class ComposeService(BaseModel):
    """Docker Compose service status"""
    name: str = Field(..., description="Service name")
    status: str = Field(..., description="Service status (running, exited, etc.)")
    health: Optional[str] = Field(default=None, description="Health status if available")
    ports: str = Field(default="", description="Port mappings")
    image: str = Field(default="", description="Docker image name")
    cpuset: str = Field(default="", description="CPU cores assigned to container")


class ComposeStatusResponse(BaseModel):
    """Response model for compose project status"""
    success: bool = Field(..., description="Whether the status check succeeded")
    project: str = Field(..., description="Project name")
    services: List[ComposeService] = Field(default=[], description="List of services and their status")
    timestamp: str = Field(..., description="Timestamp of the status check")
    error: Optional[str] = Field(default=None, description="Error details if check failed")


class ComposeOperationRequest(BaseModel):
    """Request model for compose up/down/restart/stop operations"""
    project: str = Field(..., description="Project name (e.g., 'operator-ui', 'teleop')")
    services: Optional[List[str]] = Field(default=None, description="Specific services to operate on (optional, defaults to all)")
    pull: bool = Field(default=False, description="Pull latest images before starting (for up/restart)")
    remove_volumes: bool = Field(default=False, description="Remove volumes when stopping (for down only)")
    profile: Optional[str] = Field(default=None, description="Docker Compose profile to use (e.g., 'teleop')")


class ComposeOperationResponse(BaseModel):
    """Response model for compose operations"""
    success: bool = Field(..., description="Whether the operation succeeded")
    project: str = Field(..., description="Project name")
    operation: str = Field(..., description="Operation performed (up, down, stop, restart)")
    message: str = Field(..., description="Result message")
    output: str = Field(default="", description="Command output")
    services: Optional[List[str]] = Field(default=None, description="Services affected")
    timestamp: str = Field(..., description="Timestamp of the operation")
    error: Optional[str] = Field(default=None, description="Error details if operation failed")


class ComposeLogsRequest(BaseModel):
    """Request model for compose logs"""
    project: str = Field(..., description="Project name")
    services: Optional[List[str]] = Field(default=None, description="Specific services to get logs from (optional)")
    tail: int = Field(default=100, description="Number of lines to return", ge=1, le=10000)


class ComposeLogsResponse(BaseModel):
    """Response model for compose logs"""
    success: bool = Field(..., description="Whether the command succeeded")
    project: str = Field(..., description="Project name")
    logs: List[str] = Field(default=[], description="Log lines")
    lines: int = Field(..., description="Number of lines returned")
    services: Optional[List[str]] = Field(default=None, description="Services included in logs")
    timestamp: str = Field(..., description="Timestamp of the request")
    error: Optional[str] = Field(default=None, description="Error details if command failed")


# Positronic Phantom Models
class PositronicMount(BaseModel):
    """Volume mount information"""
    source: str = Field(..., description="Source path on host")
    destination: str = Field(..., description="Destination path in container")
    mode: str = Field(default="rw", description="Mount mode (rw, ro)")


class PositronicNetwork(BaseModel):
    """Network configuration"""
    name: str = Field(..., description="Network name")
    ip_address: Optional[str] = Field(default=None, description="IP address in network")
    gateway: Optional[str] = Field(default=None, description="Gateway address")


class PositronicStatusResponse(BaseModel):
    """Response model for positronic phantom status (comprehensive like compose status)"""
    success: bool = Field(..., description="Whether the status check succeeded")
    name: str = Field(..., description="Container name")
    state: str = Field(..., description="Container state (running, exited, paused, etc.)")
    status: str = Field(..., description="Human readable status (e.g., 'Up 2 hours')")
    image: str = Field(default="", description="Image name and tag")
    created: Optional[str] = Field(default=None, description="Container creation time")
    started_at: Optional[str] = Field(default=None, description="Container start time")
    ports: str = Field(default="", description="Port mappings (host:container format)")
    cpuset: str = Field(default="", description="Runtime CPU affinity (Cpus_allowed_list)")
    memory_usage: Optional[str] = Field(default=None, description="Current memory usage")
    memory_limit: Optional[str] = Field(default=None, description="Memory limit")
    cpu_percent: Optional[str] = Field(default=None, description="CPU usage percentage")
    networks: List[PositronicNetwork] = Field(default=[], description="Network configuration")
    mounts: List[PositronicMount] = Field(default=[], description="Volume mounts")
    env: Dict[str, str] = Field(default={}, description="Key environment variables")
    timestamp: str = Field(..., description="Timestamp of the status check")
    error: Optional[str] = Field(default=None, description="Error details if check failed")


class PositronicBuildRequest(BaseModel):
    """Request model for positronic build"""
    target: str = Field(default="phantom", description="Build target (phantom, phantom-cpu, phantom-production)")


class PositronicBuildResponse(BaseModel):
    """Response model for positronic build"""
    success: bool = Field(..., description="Whether the build succeeded")
    target: str = Field(..., description="Build target used")
    message: str = Field(..., description="Result message")
    output: str = Field(default="", description="Build output (last N lines)")
    timestamp: str = Field(..., description="Timestamp of the operation")
    error: Optional[str] = Field(default=None, description="Error details if build failed")


class PositronicUpRequest(BaseModel):
    """Request model for positronic up"""
    command: str = Field(default="sleep infinity", description="Command to run in container")
    dev: bool = Field(default=True, description="Use development mode")


class PositronicUpResponse(BaseModel):
    """Response model for positronic up"""
    success: bool = Field(..., description="Whether the container started successfully")
    message: str = Field(..., description="Result message")
    output: str = Field(default="", description="Command output")
    timestamp: str = Field(..., description="Timestamp of the operation")
    error: Optional[str] = Field(default=None, description="Error details if operation failed")


class PositronicComposeUpRequest(BaseModel):
    """Request model for positronic compose up"""
    ros_domain_id: int = Field(default=101, description="ROS2 domain ID for network isolation (0-232)", ge=0, le=232)


class PositronicCpusetRequest(BaseModel):
    """Request model for positronic cpuset"""
    cpus: str = Field(default="0-14", description="CPU cores to assign (e.g., '0-14', '0,2,4')")


class PositronicCpusetResponse(BaseModel):
    """Response model for positronic cpuset"""
    success: bool = Field(..., description="Whether the cpuset was updated")
    cpus: str = Field(..., description="CPU cores assigned")
    message: str = Field(..., description="Result message")
    output: str = Field(default="", description="Command output")
    timestamp: str = Field(..., description="Timestamp of the operation")
    error: Optional[str] = Field(default=None, description="Error details if operation failed")


class PositronicStopResponse(BaseModel):
    """Response model for positronic stop"""
    success: bool = Field(..., description="Whether the container stopped successfully")
    message: str = Field(..., description="Result message")
    output: str = Field(default="", description="Command output")
    timestamp: str = Field(..., description="Timestamp of the operation")
    error: Optional[str] = Field(default=None, description="Error details if operation failed")


# Ethernet Status Models
class EthernetStatusResponse(BaseModel):
    """Response model for ethernet status endpoint"""
    is_active: bool = Field(..., description="Whether ethernet (eth0) is online and has an IP address")
    timestamp: str = Field(..., description="Timestamp of the status check")
    error: Optional[str] = Field(default=None, description="Error details if status check failed")
