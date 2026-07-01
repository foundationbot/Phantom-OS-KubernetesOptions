#!/usr/bin/env python3
"""
Simplified Phantom Control REST API Server

This server provides essential REST API endpoints for phantom system management.

Endpoints:
- POST /system/reboot - Reboot the host system
- GET  /system/stats - Get system statistics (CPU, memory, disk)
- GET  /system/stats/stream - Stream system statistics via WebSocket
- GET  /service/status - Get positronic control service status
- POST /service/start - Restart the named service (default: positronic control)
- POST /service/stop - Stop the named service (default: positronic control)
- GET  /service/logs - Get positronic control service logs
- GET  /api/status - Get service status (maps to service/status)
- GET  /api/status/{process} - Get status for a specific process (maps to service/status)
- POST /api/start/{process} - Start a specific process (maps to service/start)
- POST /api/stop/{process} - Stop a specific process (maps to service/stop)
- GET  /api/logs/{process} - Get logs for a specific process (maps to service/logs)
- POST /api/restart - Restart the system (maps to system/reboot)
- POST /api/start-all/ - Not supported (returns 501)
- POST /api/stop-all/ - Not supported (returns 501)
"""

import asyncio
import json
import logging
import os
import subprocess
import sys
import time
import threading
import psutil
from typing import Dict, List, Optional, Any
from datetime import datetime, timedelta

import uvicorn
from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

# Import utilities
from utils import get_nixos_command

# Import centralized robot configuration
from config.robotConfig import RobotConfig

# Import response models
from response_models import (
    ServiceStatusDetail,
    ServiceOperationResponse,
    ServiceLogsResponse,
    SystemRebootResponse,
    SystemStatsResponse,
    HealthCheckResponse,
    ConfigResponse,
    APIInfoResponse,
    RecordingOperationResponse,
    PolicyInfo,
    PolicyListResponse,
    PolicyRunRequest,
    PolicyRunResponse,
    PolicyStopRequest,
    PolicyStopResponse,
    PolicyRunningStatusResponse,
    PolicyLogsResponse,
    PhantomComponentStatus,
    PhantomOrchestrationStatusResponse,
    PhantomOrchestrationRequest,
    PhantomOrchestrationResponse,
    SlaveInfoResponse,
    JoystickStatusResponse,
    AdbDevice,
    AdbDevicesResponse,
    AdbReverseRequest,
    AdbReverseResponse,
    DockerContainer,
    DockerContainersResponse,
    DockerOperationResponse,
    DockerCpusetRequest,
    DockerCpusetResponse,
    DockerLogsResponse,
    ComposeProjectInfo,
    ComposeProjectsResponse,
    ComposeService,
    ComposeStatusResponse,
    ComposeOperationRequest,
    ComposeOperationResponse,
    ComposeLogsResponse,
    PositronicMount,
    PositronicNetwork,
    PositronicStatusResponse,
    PositronicBuildRequest,
    PositronicBuildResponse,
    PositronicUpRequest,
    PositronicUpResponse,
    PositronicComposeUpRequest,
    PositronicCpusetRequest,
    PositronicCpusetResponse,
    PositronicStopResponse,
    EthernetStatusResponse,
    JavaControllerComponentStatus,
    JavaControllerStatusResponse,
    JavaControllerRequest,
    JavaControllerResponse,
)

# Import service managers
from service_manager import (
    ServiceManager,
    RebootManager,
    RobotControllerManager,
    UnifiedServiceManager,
    RecordingControlManager,
    PolicyManager,
    PhantomOrchestrator,
    JavaControllerOrchestrator,
)

# Load all configuration from centralized RobotConfig
API_HOST = RobotConfig.API_HOST
API_PORT = RobotConfig.API_PORT
SERVICE_NAME = RobotConfig.SERVICE_NAME
DOCKER_SOCKET_PATH = RobotConfig.DOCKER_SOCKET_PATH
LOG_LEVEL = RobotConfig.LOG_LEVEL
LOG_FILE = RobotConfig.LOG_FILE
WEBSOCKET_MAX_CONNECTIONS = RobotConfig.WEBSOCKET_MAX_CONNECTIONS
STATS_COLLECTION_INTERVAL = RobotConfig.STATS_COLLECTION_INTERVAL
STATS_HISTORY_SIZE = RobotConfig.STATS_HISTORY_SIZE
DASHBOARD_AUTO_REFRESH = RobotConfig.DASHBOARD_AUTO_REFRESH
PHANTOM_CONTROLLER_RUNNER_PATH = RobotConfig.PHANTOM_CONTROLLER_RUNNER_PATH
PHANTOM_CONTROLLER_JSON_FILE = RobotConfig.PHANTOM_CONTROLLER_JSON_FILE
PHANTOM_CONTROLLER_INTERFACE = RobotConfig.PHANTOM_CONTROLLER_INTERFACE
USE_SUPERVISORD = RobotConfig.USE_SUPERVISORD
DOCKER_COMMAND = RobotConfig.DOCKER_COMMAND
POLICIES_DIRECTORY = RobotConfig.POLICIES_DIRECTORY
PHANTOM_CONTAINER_NAME = RobotConfig.PHANTOM_CONTAINER_NAME
PHANTOM_SCRIPT_DIRECTORY = RobotConfig.PHANTOM_SCRIPT_DIRECTORY
PHANTOM_SRC_HOME = RobotConfig.PHANTOM_SRC_HOME
COMPOSE_PROJECTS = RobotConfig.COMPOSE_PROJECTS
POSITRONIC_CONTROL_PATH = RobotConfig.POSITRONIC_CONTROL_PATH
PHANTOM_DEFAULT_CPUSET = RobotConfig.PHANTOM_DEFAULT_CPUSET
STATIC_DIR = RobotConfig.STATIC_DIR
HOME_DIR = RobotConfig.HOME_DIR
TORCH_HOME = RobotConfig.TORCH_HOME
HF_HUB_CACHE = RobotConfig.HF_HUB_CACHE


app = FastAPI(
    title="Phantom Control API",
    description="Simplified REST API for phantom system management",
    version="2.0.0",
    host=API_HOST,
    port=API_PORT
)

# Add CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Mount static files (STATIC_DIR loaded from RobotConfig)
# Only mount static files if the directory exists
if os.path.exists(STATIC_DIR):
    app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")

# Global state
service_name = SERVICE_NAME
stats_history: List[Dict] = []
stats_lock = threading.Lock()
websocket_connections: List[WebSocket] = []

# Background task for hourly stats collection
stats_collection_task: Optional[asyncio.Task] = None

# Configure logging
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL.upper()),
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler(LOG_FILE) if LOG_FILE else logging.NullHandler()
    ]
)
logger = logging.getLogger(__name__)

# Try to import NVML for GPU temperature monitoring
try:
    import pynvml
    NVML_AVAILABLE = True
except ImportError:
    NVML_AVAILABLE = False
    logger.warning("pynvml not available - GPU temperature monitoring will be disabled")

# Initialize unified service manager with service name mapping
service_name_map = {
    'positronic_control': service_name,  # Maps to phantom-positronic-control.service
    'rerun': 'phantom-rerun.service',
    'ros2-message-tracker': 'ros2-message-tracker.service',
    'locomotion_container': 'phantom-locomotion-container.service',
    'locomotion_policy': 'phantom-locomotion-policy.service',
    'locomotion_joystick': 'phantom-locomotion-joystick.service',
    'PhantomControllerRunner': 'phantom-controller.service',
    'ethernet-online': 'ethernet-online.service',  # Wait for eth0 to have IP address
    # EtherCAT motor master (host systemd) + its spine bridges. Controlled
    # from the operator-ui orchestration tab; logs surfaced via Loki.
    'dma-ethercat': 'dma-ethercat.service',
    'dma-boundary-bridge': 'dma-boundary-bridge.service',
    'dma-loop-event-bridge': 'dma-loop-event-bridge.service',
}
unified_service_manager = UnifiedServiceManager(
    service_name=service_name,
    service_name_map=service_name_map
)

# Initialize policy manager
policy_manager = PolicyManager(
    policies_directory=POLICIES_DIRECTORY,
    container_name=PHANTOM_CONTAINER_NAME,
    docker_command=DOCKER_COMMAND
)

# Initialize phantom orchestrator for coordinated startup/shutdown
phantom_orchestrator = PhantomOrchestrator(
    script_directory=PHANTOM_SCRIPT_DIRECTORY
)

# Initialize Java controller orchestrator for Java controller management
java_controller_orchestrator = JavaControllerOrchestrator()

# Request models
class ServiceRestartRequest(BaseModel):
    """Request model for service restart endpoint"""
    service_name: str = Field(..., description="Name of the service to restart (positronic_control, rerun, ros2-message-tracker, locomotion_container, locomotion_policy, locomotion_joystick, PhantomControllerRunner, ethernet-online, hardware_testing, amr_testbed, lift_testbed, robot)")
    command: Optional[Dict[str, Any]] = Field(default=None, description="Optional parameters: For positronic_control: {\"command\": \"ros2 launch...\", \"params\": {...}}. For locomotion_policy: {\"STANDING_POLICY\": \"...\", \"WALKING_POLICY\": \"...\", \"ROS_DOMAIN_ID\": \"103\"}")

class ServiceStopRequest(BaseModel):
    """Request model for service stop endpoint"""
    service_name: str = Field(..., description="Name of the service to stop (positronic_control, rerun, ros2-message-tracker, locomotion_container, locomotion_policy, locomotion_joystick, PhantomControllerRunner, ethernet-online, hardware_testing, amr_testbed, lift_testbed, robot)")

class SystemStats:
    """System statistics collector"""
    
    @staticmethod
    def get_cpu_usage() -> float:
        """Get CPU usage percentage"""
        return psutil.cpu_percent(interval=1)
    
    @staticmethod
    def get_memory_usage() -> Dict[str, Any]:
        """Get memory usage statistics"""
        memory = psutil.virtual_memory()
        return {
            "total": memory.total,
            "available": memory.available,
            "used": memory.used,
            "percentage": memory.percent,
            "free": memory.free
        }
    
    @staticmethod
    def get_disk_usage() -> Dict[str, Any]:
        """Get disk usage statistics for all mounted disks"""
        disks = {}

        # Get all disk partitions
        partitions = psutil.disk_partitions(all=False)

        for partition in partitions:
            try:
                # Skip loopback devices
                if partition.device.startswith('/dev/loop'):
                    continue

                # Get usage statistics for each partition
                usage = psutil.disk_usage(partition.mountpoint)

                disks[partition.mountpoint] = {
                    "device": partition.device,
                    "fstype": partition.fstype,
                    "total": usage.total,
                    "used": usage.used,
                    "free": usage.free,
                    "percentage": (usage.used / usage.total) * 100 if usage.total > 0 else 0
                }
            except (PermissionError, OSError) as e:
                # Skip partitions we can't access
                logger.warning(f"Cannot access disk {partition.mountpoint}: {e}")
                continue

        return disks

    @staticmethod
    def get_cpu_temperature() -> Optional[Dict[str, Any]]:
        """Get CPU temperature statistics"""
        try:
            temps = psutil.sensors_temperatures()
            if not temps:
                return None

            # Prefer coretemp (Intel/AMD CPU), fall back to other sensors
            sensor_priority = ['coretemp', 'k10temp', 'acpitz', 'cpu_thermal']
            cpu_temps = None
            sensor_label = None

            for sensor in sensor_priority:
                if sensor in temps:
                    cpu_temps = temps[sensor]
                    sensor_label = sensor
                    break

            # If no priority sensor found, use the first available
            if not cpu_temps and temps:
                sensor_label = list(temps.keys())[0]
                cpu_temps = temps[sensor_label]

            if not cpu_temps:
                return None

            # Extract temperatures
            current_temps = [t.current for t in cpu_temps if t.current]
            high_temps = [t.high for t in cpu_temps if t.high]

            if not current_temps:
                return None

            return {
                "current": round(sum(current_temps) / len(current_temps), 1),
                "high": round(max(high_temps), 1) if high_temps else None,
                "cores": [round(t, 1) for t in current_temps],
                "label": sensor_label
            }
        except Exception as e:
            logger.warning(f"Failed to get CPU temperature: {e}")
            return None

    @staticmethod
    def get_gpu_temperature() -> Optional[List[Dict[str, Any]]]:
        """Get GPU temperature statistics using NVML"""
        if not NVML_AVAILABLE:
            return None

        try:
            # Initialize NVML
            pynvml.nvmlInit()

            # Get number of GPUs
            device_count = pynvml.nvmlDeviceGetCount()

            if device_count == 0:
                pynvml.nvmlShutdown()
                return None

            # Collect temperature for each GPU
            gpu_temps = []
            for i in range(device_count):
                handle = pynvml.nvmlDeviceGetHandleByIndex(i)
                temp = pynvml.nvmlDeviceGetTemperature(handle, pynvml.NVML_TEMPERATURE_GPU)
                name = pynvml.nvmlDeviceGetName(handle)

                # Decode name if it's bytes (Python 3 compatibility)
                if isinstance(name, bytes):
                    name = name.decode('utf-8')

                gpu_temps.append({
                    "index": i,
                    "name": name,
                    "temperature": temp
                })

            # Shutdown NVML
            pynvml.nvmlShutdown()

            return gpu_temps if gpu_temps else None

        except Exception as e:
            logger.warning(f"Failed to get GPU temperature: {e}")
            try:
                pynvml.nvmlShutdown()
            except Exception:
                pass
            return None
    
    @staticmethod
    def get_system_stats() -> Dict[str, Any]:
        """Get comprehensive system statistics"""
        return {
            "timestamp": datetime.now().isoformat(),
            "cpu": {
                "usage_percent": SystemStats.get_cpu_usage(),
                "count": psutil.cpu_count(),
                "freq": psutil.cpu_freq()._asdict() if psutil.cpu_freq() else None
            },
            "memory": SystemStats.get_memory_usage(),
            "disk": SystemStats.get_disk_usage(),
            "temperature": {
                "cpu": SystemStats.get_cpu_temperature(),
                "gpu": SystemStats.get_gpu_temperature()
            },
            "uptime": time.time() - psutil.boot_time()
        }

# Background task for stats collection
async def collect_stats_hourly():
    """Collect system statistics every hour"""
    while True:
        try:
            stats = SystemStats.get_system_stats()
            
            with stats_lock:
                stats_history.append(stats)
                # Keep only configured amount of historical data
                if len(stats_history) > STATS_HISTORY_SIZE:
                    stats_history.pop(0)
            
            # Send to WebSocket connections
            if websocket_connections:
                message = json.dumps({
                    "type": "stats_update",
                    "data": stats
                })
                disconnected = []
                for connection in websocket_connections:
                    try:
                        await connection.send_text(message)
                    except:
                        disconnected.append(connection)
                
                # Remove disconnected connections
                for connection in disconnected:
                    websocket_connections.remove(connection)
            
            logger.info(f"Collected stats: CPU {stats['cpu']['usage_percent']:.1f}%, Memory {stats['memory']['percentage']:.1f}%")
            
        except Exception as e:
            logger.error(f"Error collecting stats: {e}")
        
        # Wait for configured interval
        await asyncio.sleep(STATS_COLLECTION_INTERVAL)

# Lifespan event handler (replaces deprecated on_event)
from contextlib import asynccontextmanager

@asynccontextmanager
async def lifespan(app: FastAPI):
    """Manage application lifespan."""
    global stats_collection_task
    
    # Startup
    stats_collection_task = asyncio.create_task(collect_stats_hourly())
    logger.info("Phantom Control API started")
    
    yield
    
    # Shutdown
    if stats_collection_task:
        stats_collection_task.cancel()
    logger.info("Phantom Control API stopped")

# Apply lifespan to the app
app.router.lifespan_context = lifespan

# WebSocket connection manager
class ConnectionManager:
    def __init__(self):
        self.active_connections: List[WebSocket] = []

    async def connect(self, websocket: WebSocket):
        await websocket.accept()
        self.active_connections.append(websocket)

    def disconnect(self, websocket: WebSocket):
        if websocket in self.active_connections:
            self.active_connections.remove(websocket)

    async def send_personal_message(self, message: str, websocket: WebSocket):
        await websocket.send_text(message)

    async def broadcast(self, message: str):
        for connection in self.active_connections:
            try:
                await connection.send_text(message)
            except:
                pass

manager = ConnectionManager()

# API Endpoints

@app.get("/")
async def dashboard():
    """Serve the dashboard HTML"""
    try:
        with open(f"{STATIC_DIR}/index.html", "r") as f:
            return HTMLResponse(content=f.read())
    except FileNotFoundError:
        return {
            "name": "Phantom Control API",
            "version": "2.1.0",
            "description": "Simplified REST API for phantom system management",
            "endpoints": {
                "system": {
                    "reboot": "POST /system/reboot",
                    "stats": "GET /system/stats",
                    "stats_stream": "WebSocket /system/stats/stream"
                },
                "service": {
                    "status": "GET /service/status",
                    "restart": "POST /service/start",
                    "stop": "POST /service/stop",
                    "logs": "GET /service/logs"
                },
                "recording": {
                    "stop": "POST /recording/stop",
                    "start": "POST /recording/start"
                },
                "policy": {
                    "list": "GET /policy/list",
                    "run": "POST /policy/run",
                    "run_status": "GET /policy/run/status",
                    "stop": "POST /policy/stop",
                    "logs": "GET /policy/logs"
                },
                "api": {
                    "status": "GET /api/status",
                    "status_process": "GET /api/status/{process}",
                    "start": "POST /api/start/{process}",
                    "stop": "POST /api/stop/{process}",
                    "logs": "GET /api/logs/{process}",
                    "restart": "POST /api/restart"
                }
            }
        }

@app.get("/api", response_model=APIInfoResponse)
async def api_info():
    """API information endpoint"""
    return {
        "name": "Phantom Control API",
        "version": "2.1.0",
        "description": "Simplified REST API for phantom system management",
        "endpoints": {
            "system": {
                "reboot": "POST /system/reboot",
                "stats": "GET /system/stats",
                "stats_stream": "WebSocket /system/stats/stream"
            },
            "service": {
                "status": "GET /service/status",
                "restart": "POST /service/start",
                "stop": "POST /service/stop",
                "logs": "GET /service/logs"
            },
            "recording": {
                "stop": "POST /recording/stop",
                "start": "POST /recording/start"
            },
            "policy": {
                "list": "GET /policy/list",
                "run": "POST /policy/run",
                "run_status": "GET /policy/run/status",
                "stop": "POST /policy/stop",
                "logs": "GET /policy/logs"
            },
            "api": {
                "status": "GET /api/status",
                "status_process": "GET /api/status/{process}",
                "start": "POST /api/start/{process}",
                "stop": "POST /api/stop/{process}",
                "logs": "GET /api/logs/{process}",
                "restart": "POST /api/restart"
            }
        }
    }

@app.get("/config", response_model=ConfigResponse)
async def get_config():
    """Get configuration for frontend"""
    return {
        "dashboard_auto_refresh": DASHBOARD_AUTO_REFRESH,
        "stats_collection_interval": STATS_COLLECTION_INTERVAL,
        "stats_history_size": STATS_HISTORY_SIZE,
        "service_name": SERVICE_NAME,
        "api_host": API_HOST,
        "api_port": API_PORT,
        "log_level": LOG_LEVEL,
        "robot_controller": {
            "runner_path": PHANTOM_CONTROLLER_RUNNER_PATH,
            "json_file": PHANTOM_CONTROLLER_JSON_FILE,
            "interface": PHANTOM_CONTROLLER_INTERFACE
        }
    }

@app.post("/system/reboot", response_model=SystemRebootResponse)
async def reboot_system():
    """Reboot the host system"""
    result = RebootManager.reboot_system()
    if result["success"]:
        return result
    else:
        raise HTTPException(status_code=500, detail=result["message"])

@app.get("/system/stats", response_model=SystemStatsResponse)
async def get_system_stats():
    """Get current system statistics"""
    stats = SystemStats.get_system_stats()
    
    with stats_lock:
        stats["history"] = stats_history[-STATS_HISTORY_SIZE:]  # Last configured hours
    
    return stats

@app.websocket("/system/stats/stream")
async def websocket_stats(websocket: WebSocket):
    """WebSocket endpoint for streaming system statistics"""
    await manager.connect(websocket)
    try:
        while True:
            # Send current stats every 5 seconds
            stats = SystemStats.get_system_stats()
            await websocket.send_text(json.dumps({
                "type": "stats",
                "data": stats
            }))
            await asyncio.sleep(5)
    except WebSocketDisconnect:
        manager.disconnect(websocket)

@app.get("/service/status", response_model=List[ServiceStatusDetail])
async def get_service_status(service_name: str = None):
    """Get service status.

    **Query parameters:**
    - `service_name` (optional): if given, return status for just that
      friendly service (e.g. `dma-ethercat`). If omitted, returns the
      default AI service set (positronic_control, rerun,
      ros2-message-tracker, locomotion_container, locomotion_policy,
      locomotion_joystick, PhantomControllerRunner).
    """
    if service_name:
        if not UnifiedServiceManager.validate_service_name(service_name):
            raise HTTPException(status_code=400, detail=f"Invalid service name: {service_name}")
        service_names = [service_name]
    else:
        service_names = ['positronic_control', 'rerun', 'ros2-message-tracker', 'locomotion_container', 'locomotion_policy', 'locomotion_joystick', 'PhantomControllerRunner']
    systemd_names = [UnifiedServiceManager.map_to_systemd_name(name) for name in service_names]
    return UnifiedServiceManager.get_multiple_services_status(systemd_names)

@app.post("/service/start", response_model=ServiceOperationResponse)
async def restart_service(request: ServiceRestartRequest):
    """
    Restart a service by name with optional parameter overrides.

    **Request body:**
    - `service_name` (required): Name of service
    - `command` (optional): Parameter overrides

    **Supported services:**

    positronic_control, rerun, ros2-message-tracker, locomotion_container,
    locomotion_policy, locomotion_joystick, PhantomControllerRunner,
    ethernet-online, hardware_testing, amr_testbed, lift_testbed, robot

    ---

    ## Parameter Overrides

    ### positronic_control

    ```json
    {
      "command": "ros2 launch <package> <launch_file>",
      "params": {
        "y_drift": "true",
        "record": "true",
        "location": "production",
        "insertion": "true",
        "experimental": "true",
        "slam": "true",
        "pickup": "true",
        "remap": "false",
        "z_offset": "true"
      }
    }
    ```

    **Default launch:** `ros2 launch srg_localization global_positioning_launch.py`

    **Defaults:** y_drift=true, record=true, location=production, insertion=true,
    experimental=true, slam=true, pickup=true, remap=false, z_offset=true

    ---

    ### locomotion_policy

    ```json
    {
      "STANDING_POLICY": "2025-09-22_12-29-04",
      "WALKING_POLICY": "2025-10-09_09-12-30-latency",
      "ROS_DOMAIN_ID": "103"
    }
    ```

    **Defaults:** STANDING_POLICY="2025-09-22_12-29-04",
    WALKING_POLICY="2025-10-09_09-12-30-latency",
    ROS_DOMAIN_ID="103"

    ---

    All parameters are optional. User-provided parameters override defaults.
    """
    result = unified_service_manager.restart_service(request.service_name, command=request.command)

    if result["success"]:
        return result
    else:
        # Return appropriate error code based on the error
        if "Invalid service name" in result.get("message", ""):
            raise HTTPException(status_code=400, detail=result["message"])
        else:
            raise HTTPException(status_code=500, detail=result["message"])

@app.post("/service/stop", response_model=ServiceOperationResponse)
async def stop_service(request: ServiceStopRequest):
    """
    Stop a service by name

    Request body:
    - service_name (required): Name of service (positronic_control, rerun, ros2-message-tracker, locomotion_container, locomotion_policy, locomotion_joystick, PhantomControllerRunner, ethernet-online, hardware_testing, amr_testbed, lift_testbed, robot)
    """
    result = unified_service_manager.stop_service(request.service_name)

    if result["success"]:
        return result
    else:
        # Return appropriate error code based on the error
        if "Invalid service name" in result.get("message", ""):
            raise HTTPException(status_code=400, detail=result["message"])
        else:
            raise HTTPException(status_code=500, detail=result["message"])

@app.get("/service/logs", response_model=ServiceLogsResponse)
async def get_service_logs(service_name: str = 'positronic_control', lines: int = 100):
    """
    Get logs for AI services via journalctl

    **Query parameters:**
    - `service_name` (optional): Name of the AI service (default: 'positronic_control')
    - `lines` (optional): Number of log lines to return (default: 100, max: 1000)

    **Supported AI services:**
    - positronic_control
    - rerun
    - ros2-message-tracker
    - locomotion_container
    - locomotion_policy
    - locomotion_joystick
    - PhantomControllerRunner
    - ethernet-online
    """
    if lines > 1000:
        lines = 1000  # Limit to prevent memory issues

    result = UnifiedServiceManager.get_service_logs_by_name(service_name, lines)

    # Check if there was an error
    if "error" in result and result["lines"] == 0:
        raise HTTPException(status_code=400, detail=result["error"])

    return result


@app.get("/service/loki-logs", response_model=ServiceLogsResponse)
async def get_service_loki_logs(service_name: str = 'dma-ethercat', lines: int = 200):
    """
    Get logs for a host service from Loki (gaia log store).

    Unlike /service/logs (live journalctl on this host), this returns
    history that survives restarts and aggregates the related labels
    (e.g. for dma-ethercat: the unit, the RT .master, and the spine
    bridges). Loki endpoint is configurable via the LOKI_URL env var
    (default http://localhost:10310; gaia runs hostNetwork).

    **Query parameters:**
    - `service_name` (optional): host service (default: 'dma-ethercat')
    - `lines` (optional): max lines (default: 200, max: 1000)
    """
    import time
    import httpx

    if lines > 1000:
        lines = 1000

    loki_url = os.environ.get("LOKI_URL", "http://localhost:10310").rstrip("/")
    # dma-ethercat: match the unit + RT .master + spine bridges. Others: <name>.* .
    if service_name == "dma-ethercat":
        selector = '{service_name=~"dma-ethercat.*|dma-(boundary|loop-event)-bridge.service"}'
    else:
        selector = '{service_name=~"%s.*"}' % service_name

    end_ns = time.time_ns()
    start_ns = end_ns - 3600 * 1_000_000_000  # last hour
    params = {
        "query": selector,
        "limit": str(lines),
        "start": str(start_ns),
        "end": str(end_ns),
        "direction": "backward",
    }
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.get(f"{loki_url}/loki/api/v1/query_range", params=params)
            resp.raise_for_status()
            data = resp.json()
        entries = []  # (ts_ns, line)
        for stream in data.get("data", {}).get("result", []):
            for value in stream.get("values", []):
                entries.append((int(value[0]), value[1]))
        entries.sort(key=lambda e: e[0])  # chronological
        logs = [line for _, line in entries][-lines:]
        return ServiceLogsResponse(
            service_name=service_name, source="loki", lines=len(logs),
            logs=logs, timestamp=datetime.now().isoformat(),
        )
    except Exception as e:
        return ServiceLogsResponse(
            service_name=service_name, source="loki", lines=0, logs=[],
            timestamp=datetime.now().isoformat(),
            error=f"Loki query failed ({loki_url}): {e}",
        )


@app.get("/service/logs/stream")
async def stream_service_logs(service_name: str = 'positronic_control'):
    """
    Stream logs for a systemd service in real-time using Server-Sent Events (SSE).

    **Query Parameters:**
    - `service_name`: Name of the service (default: 'positronic_control')

    **Supported services:**
    - positronic_control
    - rerun
    - ros2-message-tracker
    - locomotion_container
    - locomotion_policy
    - locomotion_joystick
    - PhantomControllerRunner
    - ethernet-online

    **Usage:**
    ```
    curl -N "http://localhost:5000/service/logs/stream?service_name=positronic_control"
    ```
    """
    # Map friendly name to systemd service name
    systemd_name = UnifiedServiceManager.map_to_systemd_name(service_name)

    def generate():
        process = None
        try:
            process = subprocess.Popen(
                ['stdbuf', '-oL', 'journalctl', '-f', '-u', systemd_name, '-o', 'cat', '--no-pager'],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                bufsize=0
            )

            while True:
                line = process.stdout.readline()
                if not line:
                    if process.poll() is not None:
                        break
                    continue

                decoded_line = line.decode('utf-8', errors='replace').rstrip()
                yield f"data: {decoded_line}\n\n"

        except Exception as e:
            yield f"data: Error streaming logs: {str(e)}\n\n"
        finally:
            if process and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no"
        }
    )


# ============================================================================
# ETHERNET STATUS ENDPOINTS
# ============================================================================

@app.get("/ethernet/status", response_model=EthernetStatusResponse)
async def get_ethernet_status():
    """
    Check if ethernet (eth0) is online.

    Returns is_active: true if the ethernet-online systemd service has completed
    successfully, meaning eth0 has an IP address.
    """
    try:
        # Check ethernet-online service status using systemctl
        result = subprocess.run(
            ['systemctl', 'is-active', 'ethernet-online'],
            capture_output=True,
            text=True,
            timeout=10
        )

        # is-active returns "active" if the service is active (including exited successfully)
        is_active = result.stdout.strip() == "active"

        return EthernetStatusResponse(
            is_active=is_active,
            timestamp=datetime.now().isoformat()
        )

    except Exception as e:
        logger.error(f"Error checking ethernet status: {e}")
        return EthernetStatusResponse(
            is_active=False,
            timestamp=datetime.now().isoformat(),
            error=str(e)
        )


@app.post("/recording/stop", response_model=RecordingOperationResponse)
async def stop_recording():
    """
    Stop recording by publishing to ROS2 topic

    This endpoint checks if the positronic-control system service (positronic_phantom container) is running,
    and if so, executes the command to stop recording inside the container:
    `ros2 topic pub -1 /task_msgs/cladding_task_state task_msgs/msg/CladdingTaskMessage "state: DO_NOTHING"`

    Returns:
        RecordingOperationResponse: Result of the stop recording operation
    """
    container_name = PHANTOM_CONTAINER_NAME
    command = 'source /src/workspace/install/setup.bash && ros2 topic pub -1 /task_msgs/cladding_task_state task_msgs/msg/CladdingTaskMessage "{state: DO_NOTHING}"'

    result = RecordingControlManager.execute_command_in_container(container_name, command, docker_command=DOCKER_COMMAND)

    if not result["success"]:
        # Return appropriate error code based on the error
        if "not running" in result.get("message", "").lower():
            raise HTTPException(status_code=503, detail=result["message"])
        else:
            raise HTTPException(status_code=500, detail=result["message"])

    return result

@app.post("/recording/start", response_model=RecordingOperationResponse)
async def start_recording():
    """
    Start/restart recording by publishing to ROS2 topic

    This endpoint checks if the positronic-control system service (positronic_phantom container) is running,
    and if so, executes the command to start recording inside the container:
    `ros2 topic pub -1 /task_msgs/cladding_task_state task_msgs/msg/CladdingTaskMessage "state: ABC"`

    Returns:
        RecordingOperationResponse: Result of the start recording operation
    """
    container_name = PHANTOM_CONTAINER_NAME
    command = 'source /src/workspace/install/setup.bash && ros2 topic pub -1 /task_msgs/cladding_task_state task_msgs/msg/CladdingTaskMessage "{state: ABC}"'

    result = RecordingControlManager.execute_command_in_container(container_name, command, docker_command=DOCKER_COMMAND)

    if not result["success"]:
        # Return appropriate error code based on the error
        if "not running" in result.get("message", "").lower():
            raise HTTPException(status_code=503, detail=result["message"])
        else:
            raise HTTPException(status_code=500, detail=result["message"])

    return result

# Additional API endpoints for compatibility with robot.deployment
@app.post("/api/start/{process}", response_model=ServiceOperationResponse)
async def start_process(process: str):
    """
    Start a specific process (maps to service/start)

    Args:
        process: Name of the process to start
    """
    result = unified_service_manager.restart_service(process)

    if result["success"]:
        return result
    else:
        # Return appropriate error code based on the error
        if "Invalid service name" in result.get("message", ""):
            raise HTTPException(status_code=404, detail=f"Process {process} not found")
        else:
            raise HTTPException(status_code=500, detail=result["message"])

@app.post("/api/stop/{process}", response_model=ServiceOperationResponse)
async def stop_process(process: str):
    """
    Stop a specific process (maps to service/stop)

    Args:
        process: Name of the process to stop
    """
    result = unified_service_manager.stop_service(process)

    if result["success"]:
        return result
    else:
        # Return appropriate error code based on the error
        if "Invalid service name" in result.get("message", ""):
            raise HTTPException(status_code=404, detail=f"Process {process} not found")
        else:
            raise HTTPException(status_code=500, detail=result["message"])

@app.get("/api/logs/{process}", response_model=ServiceLogsResponse)
async def get_process_logs(process: str, lines: int = 100):
    """
    Get logs for a specific AI service via journalctl

    **Path parameter:**
    - `process` (required): Name of the AI service

    **Query parameter:**
    - `lines` (optional): Number of log lines to return (default: 100, max: 1000)

    **Supported AI services:**
    - positronic_control
    - rerun
    - ros2-message-tracker
    - locomotion_container
    - locomotion_policy
    - locomotion_joystick
    - PhantomControllerRunner
    - ethernet-online
    """
    if lines > 1000:
        lines = 1000  # Limit to prevent memory issues

    result = UnifiedServiceManager.get_service_logs_by_name(process, lines)

    # Check if there was an error
    if "error" in result and result["lines"] == 0:
        raise HTTPException(status_code=400, detail=result["error"])

    return result


@app.get("/api/logs/{process}/stream")
async def stream_process_logs(process: str):
    """
    Stream logs for a specific AI service in real-time using Server-Sent Events (SSE).

    **Path Parameter:**
    - `process`: Name of the AI service

    **Supported AI services:**
    - positronic_control
    - rerun
    - ros2-message-tracker
    - locomotion_container
    - locomotion_policy
    - locomotion_joystick
    - PhantomControllerRunner
    - ethernet-online

    **Usage:**
    ```
    curl -N "http://localhost:5000/api/logs/positronic_control/stream"
    ```
    """
    # Map friendly name to systemd service name
    systemd_name = UnifiedServiceManager.map_to_systemd_name(process)

    def generate():
        process_handle = None
        try:
            process_handle = subprocess.Popen(
                ['stdbuf', '-oL', 'journalctl', '-f', '-u', systemd_name, '-o', 'cat', '--no-pager'],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                bufsize=0
            )

            while True:
                line = process_handle.stdout.readline()
                if not line:
                    if process_handle.poll() is not None:
                        break
                    continue

                decoded_line = line.decode('utf-8', errors='replace').rstrip()
                yield f"data: {decoded_line}\n\n"

        except Exception as e:
            yield f"data: Error streaming logs: {str(e)}\n\n"
        finally:
            if process_handle and process_handle.poll() is None:
                process_handle.terminate()
                try:
                    process_handle.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process_handle.kill()

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no"
        }
    )


@app.get("/api/status", response_model=List[ServiceStatusDetail])
async def get_status():
    """
    Get status for AI services (maps to service/status)

    Returns status information for positronic_control, rerun, ros2-message-tracker, locomotion_container, locomotion_policy, locomotion_joystick, and PhantomControllerRunner
    """
    # Get status for all AI services
    service_names = ['positronic_control', 'rerun', 'ros2-message-tracker', 'locomotion_container', 'locomotion_policy', 'locomotion_joystick', 'PhantomControllerRunner']
    systemd_names = [UnifiedServiceManager.map_to_systemd_name(name) for name in service_names]
    return UnifiedServiceManager.get_multiple_services_status(systemd_names)

@app.get("/api/status/{process_name}", response_model=List[ServiceStatusDetail])
async def get_process_status(process_name: str):
    """
    Get status of a specific process

    Args:
        process_name: Name of the process to get status for (e.g., positronic_control, rerun, ros2-message-tracker)

    Returns:
        Status information for the requested service
    """
    # Map the friendly name to systemd service name
    systemd_name = UnifiedServiceManager.map_to_systemd_name(process_name)

    # Get status for the specific service
    status = UnifiedServiceManager.get_systemd_service_status(systemd_name)
    return [status]

@app.post("/api/restart", response_model=SystemRebootResponse)
async def restart_system():
    """
    Restart the system (maps to system/reboot)
    """
    result = RebootManager.reboot_system()
    
    if result["success"]:
        return result
    else:
        raise HTTPException(status_code=500, detail=result["message"])

@app.post("/api/start-all/")
async def start_all_processes():
    """
    Start all processes - NOT SUPPORTED
    """
    raise HTTPException(
        status_code=501, 
        detail="start-all functionality is not supported in this API. Use individual process endpoints instead."
    )

@app.post("/api/stop-all/")
async def stop_all_processes():
    """
    Stop all processes - NOT SUPPORTED
    """
    raise HTTPException(
        status_code=501, 
        detail="stop-all functionality is not supported in this API. Use individual process endpoints instead."
    )

# Health check endpoint
@app.get("/health", response_model=HealthCheckResponse)
async def health_check():
    """Health check endpoint"""
    return {
        "status": "healthy",
        "timestamp": datetime.now().isoformat(),
        "service": service_name,
        "uptime": time.time() - psutil.boot_time()
    }


# ============================================================================
# Policy Management Endpoints
# ============================================================================

@app.get("/policy/list", response_model=PolicyListResponse)
async def list_policies():
    """
    List all available policies in the policies directory.

    Returns a list of policy directories with metadata including:
    - Policy name and path
    - Policy type (velocity, tracking_jointspace, tracking_taskspace)
    - Number of available checkpoints
    - Latest checkpoint number
    - Whether DVBF model is available
    """
    result = policy_manager.list_policies()

    if not result["success"]:
        raise HTTPException(status_code=500, detail=result.get("error", "Failed to list policies"))

    return result


@app.post("/policy/run", response_model=PolicyRunResponse)
async def run_policy(request: PolicyRunRequest):
    """
    Run a policy in the positronic_phantom container.

    This endpoint:
    1. Optionally rebuilds the ROS2 workspace (if rebuild=true)
    2. Launches the policy with the specified parameters

    **Request Body:**
    - `policy_name`: Name of the policy (from /policy/list)
    - `teleop`: Enable teleop mode (default: false)
    - `ros_domain_id`: ROS2 domain ID (default: 103)
    - `rebuild`: Run colcon build before launching (default: true, set false for faster restart)

    **Note:** This is a long-running operation. The policy will continue running
    in the container after this endpoint returns.
    """
    try:
        import re
        docker_cmd = get_nixos_command('docker')

        # Check if a policy is already running (colcon build or ros2 launch)
        existing_check = subprocess.run(
            [docker_cmd, 'exec', PHANTOM_CONTAINER_NAME, 'pgrep', '-f', 'ros2 launch phantom_policies'],
            capture_output=True,
            text=True,
            timeout=10
        )
        if existing_check.returncode == 0 and existing_check.stdout.strip():
            existing_pid = existing_check.stdout.strip().split('\n')[0]
            return PolicyRunResponse(
                success=False,
                message="A policy is already running",
                policy_name=request.policy_name,
                policy_path="",
                teleop=request.teleop,
                output=[],
                timestamp=datetime.now().isoformat(),
                pid=int(existing_pid),
                error=f"Stop the existing policy first (PID: {existing_pid}) using /policy/stop"
            )

        # Check if colcon build is running
        colcon_check = subprocess.run(
            [docker_cmd, 'exec', PHANTOM_CONTAINER_NAME, 'pgrep', '-f', 'colcon'],
            capture_output=True,
            text=True,
            timeout=10
        )
        if colcon_check.returncode == 0 and colcon_check.stdout.strip():
            existing_pid = colcon_check.stdout.strip().split('\n')[0]
            return PolicyRunResponse(
                success=False,
                message="A policy build is already in progress",
                policy_name=request.policy_name,
                policy_path="",
                teleop=request.teleop,
                output=[],
                timestamp=datetime.now().isoformat(),
                pid=int(existing_pid),
                error=f"A build is in progress (PID: {existing_pid}). Wait for it to complete or stop it using /policy/stop"
            )

        # Validate policy name to prevent command injection
        if not re.match(r'^[\w\-\.]+$', request.policy_name):
            return PolicyRunResponse(
                success=False,
                message="Invalid policy name format",
                policy_name=request.policy_name,
                policy_path="",
                teleop=request.teleop,
                output=[],
                timestamp=datetime.now().isoformat(),
                error="Policy name can only contain letters, numbers, dashes, underscores, and dots"
            )

        # Check if policy exists (uses POLICIES_DIRECTORY from RobotConfig)
        models_path = POLICIES_DIRECTORY
        policy_host_path = os.path.join(models_path, request.policy_name)
        if not os.path.isdir(policy_host_path):
            return PolicyRunResponse(
                success=False,
                message=f"Policy not found: {request.policy_name}",
                policy_name=request.policy_name,
                policy_path="",
                teleop=request.teleop,
                output=[],
                timestamp=datetime.now().isoformat(),
                error=f"Policy directory does not exist: {policy_host_path}"
            )

        # Build the docker exec command
        # Policy path uses PHANTOM_MODELS env var inside container
        policy_container_path = f"$PHANTOM_MODELS/{request.policy_name}"

        # Build ros2 launch command
        launch_cmd = f"ros2 launch phantom_policies phantom_launch.py policy_path:={policy_container_path}"
        if request.teleop:
            launch_cmd += " teleop:=true"

        # Full command with optional rebuild
        # Output redirected to log file for /policy/logs endpoint
        # Use subshell with redirection at the end for reliable log capture
        # PYTHONUNBUFFERED=1 ensures ros2 output isn't buffered
        log_file = "/tmp/policy_run.log"

        if request.rebuild:
            # Full rebuild: clean and build workspace
            full_cmd = (
                f"( export PYTHONUNBUFFERED=1 && "
                f"export ROS_DOMAIN_ID={request.ros_domain_id} && "
                "rm -rf ./install ./build && "
                "source /opt/ros/humble/setup.bash && "
                "colcon build --packages-ignore ros_to_rerun_bridge && "
                "source ./install/setup.bash && "
                f"{launch_cmd} "
                f") > {log_file} 2>&1"
            )
        else:
            # Skip build: just source and launch (faster restart)
            full_cmd = (
                f"( export PYTHONUNBUFFERED=1 && "
                f"export ROS_DOMAIN_ID={request.ros_domain_id} && "
                "source /opt/ros/humble/setup.bash && "
                "source ./install/setup.bash && "
                f"{launch_cmd} "
                f") > {log_file} 2>&1"
            )

        # Run the command in detached mode with working directory set
        # -d: detached mode (doesn't block)
        # -w: set working directory to /src/workspace
        result = subprocess.run(
            [docker_cmd, 'exec', '-d', '-w', '/src/workspace', PHANTOM_CONTAINER_NAME, 'bash', '-c', full_cmd],
            capture_output=True,
            text=True,
            timeout=300  # 5 minute timeout
        )

        output = (result.stdout + result.stderr).strip()
        output_lines = [line for line in output.split('\n') if line]

        if result.returncode != 0:
            return PolicyRunResponse(
                success=False,
                message=f"Failed to run policy {request.policy_name}",
                policy_name=request.policy_name,
                policy_path=policy_container_path,
                teleop=request.teleop,
                output=output_lines,
                timestamp=datetime.now().isoformat(),
                error=f"docker exec exited with code {result.returncode}"
            )

        # Wait briefly for process to start, then query for PID
        time.sleep(0.5)
        pid = None
        try:
            pid_result = subprocess.run(
                [docker_cmd, 'exec', PHANTOM_CONTAINER_NAME, 'pgrep', '-f', request.policy_name],
                capture_output=True,
                text=True,
                timeout=10
            )
            if pid_result.returncode == 0 and pid_result.stdout.strip():
                # Take the first PID (parent bash process)
                pid = int(pid_result.stdout.strip().split('\n')[0])
        except Exception as e:
            logger.warning(f"Failed to get PID for policy {request.policy_name}: {e}")

        return PolicyRunResponse(
            success=True,
            message=f"Policy {request.policy_name} launched successfully" + (" with teleop mode" if request.teleop else ""),
            policy_name=request.policy_name,
            policy_path=policy_container_path,
            teleop=request.teleop,
            output=output_lines,
            timestamp=datetime.now().isoformat(),
            pid=pid
        )

    except subprocess.TimeoutExpired:
        return PolicyRunResponse(
            success=False,
            message="Policy launch timed out",
            policy_name=request.policy_name,
            policy_path=f"$PHANTOM_MODELS/{request.policy_name}",
            teleop=request.teleop,
            output=[],
            timestamp=datetime.now().isoformat(),
            error="Build/launch timed out after 5 minutes"
        )
    except Exception as e:
        logger.error(f"Error running policy: {e}")
        return PolicyRunResponse(
            success=False,
            message="Error running policy",
            policy_name=request.policy_name,
            policy_path=f"$PHANTOM_MODELS/{request.policy_name}",
            teleop=request.teleop,
            output=[],
            timestamp=datetime.now().isoformat(),
            error=str(e)
        )


@app.post("/policy/stop", response_model=PolicyStopResponse)
async def stop_policy(request: PolicyStopRequest = None):
    """
    Stop all running policy processes and shut down the container.

    Performs a graceful shutdown sequence:
    1. Sends ROS 2 stop signal via /phantom/stop_policy topic (graceful 1-sec shutdown)
    2. Waits 3 seconds for robot stiffness to transition to zero
    3. Force kills any remaining processes (fallback)
    4. Stops the positronic_phantom container via docker compose down

    **Request Body (optional):**
    - `pid`: Specific process ID to kill (optional - if not provided, kills all policy processes)
    """
    try:
        docker_cmd = get_nixos_command('docker')
        killed_processes = []

        # Step 1: Try graceful ROS 2 stop via /phantom/stop_policy topic
        # This triggers a safe 1-second shutdown with stiffness interpolation to zero
        graceful_cmd = [
            docker_cmd, 'exec', PHANTOM_CONTAINER_NAME, 'bash', '-c',
            'source /opt/ros/humble/setup.bash && '
            'ros2 topic pub --once /phantom/stop_policy std_msgs/msg/Bool "{data: true}"'
        ]
        try:
            result = subprocess.run(graceful_cmd, capture_output=True, text=True, timeout=10)
            if result.returncode == 0:
                killed_processes.append("graceful_ros2_stop")
                logger.info("Sent graceful ROS 2 stop signal")
        except subprocess.TimeoutExpired:
            logger.warning("Graceful ROS 2 stop timed out, proceeding with force kill")
        except Exception as e:
            logger.warning(f"Graceful ROS 2 stop failed: {e}, proceeding with force kill")

        # Step 2: Wait for graceful shutdown (robot stiffness transitions to zero)
        await asyncio.sleep(3)

        # Step 3: Force kill any remaining processes (fallback)
        # If specific PID provided, kill it first
        if request and request.pid:
            result = subprocess.run(
                [docker_cmd, 'exec', PHANTOM_CONTAINER_NAME, 'kill', '-9', str(request.pid)],
                capture_output=True,
                text=True,
                timeout=10
            )
            if result.returncode == 0:
                killed_processes.append(f"PID {request.pid}")

        # Kill remaining policy-related processes
        kill_patterns = [
            ('ros2.*launch.*phantom_policies', 'ros2_launch'),
            ('phantom_policies', 'phantom_policies'),
            ('python.*colcon', 'colcon_build'),
            ('bash.*PHANTOM_MODELS', 'bash_parent'),
        ]

        for pattern, name in kill_patterns:
            try:
                result = subprocess.run(
                    [docker_cmd, 'exec', PHANTOM_CONTAINER_NAME, 'pkill', '-9', '-f', pattern],
                    capture_output=True,
                    text=True,
                    timeout=10
                )
                if result.returncode == 0 and name not in killed_processes:
                    killed_processes.append(name)
            except Exception:
                pass  # Ignore errors, container may already be stopping

        # Step 4: Stop container via docker compose down
        compose_file = os.path.join(POSITRONIC_CONTROL_PATH, 'docker', 'development.docker-compose.yaml')
        try:
            compose_result = subprocess.run(
                [docker_cmd, 'compose', '-f', compose_file, 'down', '-t', '60'],
                cwd=POSITRONIC_CONTROL_PATH,
                capture_output=True,
                text=True,
                timeout=120,
                env=_get_compose_env()
            )
            if compose_result.returncode == 0:
                killed_processes.append("container_stopped")
                logger.info("Container stopped via docker compose down")
            else:
                logger.warning(f"docker compose down returned {compose_result.returncode}: {compose_result.stderr}")
        except subprocess.TimeoutExpired:
            logger.error("docker compose down timed out")
        except Exception as e:
            logger.error(f"docker compose down failed: {e}")

        return PolicyStopResponse(
            success=True,
            message="Policy stopped and container shut down" if "container_stopped" in killed_processes else "Policy processes stopped",
            killed_processes=killed_processes,
            timestamp=datetime.now().isoformat()
        )

    except subprocess.TimeoutExpired:
        return PolicyStopResponse(
            success=False,
            message="Stop command timed out",
            killed_processes=[],
            timestamp=datetime.now().isoformat(),
            error="Kill command timed out"
        )
    except Exception as e:
        logger.error(f"Error stopping policy: {e}")
        return PolicyStopResponse(
            success=False,
            message="Error stopping policy",
            killed_processes=[],
            timestamp=datetime.now().isoformat(),
            error=str(e)
        )


@app.get("/policy/run/status", response_model=PolicyRunningStatusResponse)
async def get_policy_run_status():
    """
    Check the current status of a running policy.

    Returns status indicating which step the policy is at:
    - idle: No policy process running
    - starting: Process started, preparing environment
    - building: colcon build in progress
    - running: ros2 launch active, policy is running
    - stopped: Process was stopped
    - error: Process failed or crashed
    """
    try:
        docker_cmd = get_nixos_command('docker')

        # Check if container is running first
        container_check = subprocess.run(
            [docker_cmd, 'ps', '-q', '-f', f'name={PHANTOM_CONTAINER_NAME}'],
            capture_output=True,
            text=True,
            timeout=10
        )

        if not container_check.stdout.strip():
            return PolicyRunningStatusResponse(
                success=True,
                status="error",
                step="Container not running",
                policy_name=None,
                pid=None,
                timestamp=datetime.now().isoformat(),
                error=f"{PHANTOM_CONTAINER_NAME} container is not running"
            )

        # Check for colcon build process FIRST (if colcon running, we're still building)
        # Look specifically for python colcon process, not bash parent
        colcon_check = subprocess.run(
            [docker_cmd, 'exec', PHANTOM_CONTAINER_NAME, 'pgrep', '-af', 'python.*colcon'],
            capture_output=True,
            text=True,
            timeout=10
        )

        if colcon_check.returncode == 0 and colcon_check.stdout.strip():
            pid = int(colcon_check.stdout.strip().split('\n')[0].split()[0])
            return PolicyRunningStatusResponse(
                success=True,
                status="building",
                step="Colcon build in progress",
                policy_name=None,
                pid=pid,
                timestamp=datetime.now().isoformat()
            )

        # Check for ros2 launch - look for the actual launch process
        # Pattern matches ros2 launch phantom_policies regardless of how python is invoked
        ros2_check = subprocess.run(
            [docker_cmd, 'exec', PHANTOM_CONTAINER_NAME, 'pgrep', '-af', 'ros2.*launch.*phantom_policies'],
            capture_output=True,
            text=True,
            timeout=10
        )

        if ros2_check.returncode == 0 and ros2_check.stdout.strip():
            lines = ros2_check.stdout.strip().split('\n')
            pid = int(lines[0].split()[0])
            # Try to extract policy name from command (last path component)
            policy_name = None
            for line in lines:
                if 'policy_path:=' in line:
                    import re
                    # Use greedy .* to match up to the LAST slash
                    match = re.search(r'policy_path:=.*/([^/\s]+)', line)
                    if match:
                        policy_name = match.group(1)
                    break

            return PolicyRunningStatusResponse(
                success=True,
                status="running",
                step="Policy is active",
                policy_name=policy_name,
                pid=pid,
                timestamp=datetime.now().isoformat()
            )

        # Also check for phantom_policies node processes (launched by ros2 launch)
        # These are the actual policy executables that run after launch completes
        node_check = subprocess.run(
            [docker_cmd, 'exec', PHANTOM_CONTAINER_NAME, 'pgrep', '-af', 'phantom_policies'],
            capture_output=True,
            text=True,
            timeout=10
        )

        if node_check.returncode == 0 and node_check.stdout.strip():
            # Filter out bash/colcon/pgrep processes, only count actual policy nodes
            lines = [l for l in node_check.stdout.strip().split('\n')
                     if l and 'pgrep' not in l and 'bash' not in l and 'colcon' not in l]
            if lines:
                pid = int(lines[0].split()[0])
                # Extract policy name if present
                policy_name = None
                for line in lines:
                    if 'policy_path:=' in line:
                        import re
                        match = re.search(r'policy_path:=.*/([^/\s]+)', line)
                        if match:
                            policy_name = match.group(1)
                        break

                return PolicyRunningStatusResponse(
                    success=True,
                    status="running",
                    step="Policy is active",
                    policy_name=policy_name,
                    pid=pid,
                    timestamp=datetime.now().isoformat()
                )

        # Check for bash process running our command (starting/sourcing phase)
        bash_check = subprocess.run(
            [docker_cmd, 'exec', PHANTOM_CONTAINER_NAME, 'pgrep', '-af', 'bash.*PHANTOM_MODELS'],
            capture_output=True,
            text=True,
            timeout=10
        )

        if bash_check.returncode == 0 and bash_check.stdout.strip():
            pid = int(bash_check.stdout.strip().split('\n')[0].split()[0])
            return PolicyRunningStatusResponse(
                success=True,
                status="starting",
                step="Preparing environment",
                policy_name=None,
                pid=pid,
                timestamp=datetime.now().isoformat()
            )

        # Nothing running
        return PolicyRunningStatusResponse(
            success=True,
            status="idle",
            step=None,
            policy_name=None,
            pid=None,
            timestamp=datetime.now().isoformat()
        )

    except subprocess.TimeoutExpired:
        return PolicyRunningStatusResponse(
            success=False,
            status="error",
            step=None,
            policy_name=None,
            pid=None,
            timestamp=datetime.now().isoformat(),
            error="Status check timed out"
        )
    except Exception as e:
        logger.error(f"Error checking policy status: {e}")
        return PolicyRunningStatusResponse(
            success=False,
            status="error",
            step=None,
            policy_name=None,
            pid=None,
            timestamp=datetime.now().isoformat(),
            error=str(e)
        )


# ============================================================================
# Policy Logs Endpoints
# ============================================================================

@app.get("/policy/logs", response_model=PolicyLogsResponse)
async def get_policy_logs(tail: int = 100):
    """
    Get logs from the policy run log file inside the container.

    Args:
        tail: Number of log lines to retrieve (default 100, max 1000)

    Returns:
        PolicyLogsResponse with policy run logs
    """
    # Limit lines to prevent excessive output
    tail = min(tail, 1000)

    try:
        docker_cmd = get_nixos_command('docker')
        log_file = "/tmp/policy_run.log"

        # Check if container is running
        container_check = subprocess.run(
            [docker_cmd, 'ps', '-q', '-f', f'name={PHANTOM_CONTAINER_NAME}'],
            capture_output=True,
            text=True,
            timeout=10
        )
        container_running = bool(container_check.stdout.strip())

        if not container_running:
            return PolicyLogsResponse(
                success=False,
                container_name=PHANTOM_CONTAINER_NAME,
                container_running=False,
                logs=[],
                lines=0,
                timestamp=datetime.now().isoformat(),
                error=f"Container {PHANTOM_CONTAINER_NAME} is not running"
            )

        # Read log file from container
        result = subprocess.run(
            [docker_cmd, 'exec', PHANTOM_CONTAINER_NAME, 'tail', '-n', str(tail), log_file],
            capture_output=True,
            text=True,
            timeout=30
        )

        if result.returncode != 0:
            # Log file might not exist yet
            return PolicyLogsResponse(
                success=True,
                container_name=PHANTOM_CONTAINER_NAME,
                container_running=True,
                logs=[],
                lines=0,
                timestamp=datetime.now().isoformat(),
                error="No logs available yet (log file not found)"
            )

        log_lines = [line for line in result.stdout.split('\n') if line]

        return PolicyLogsResponse(
            success=True,
            container_name=PHANTOM_CONTAINER_NAME,
            container_running=True,
            logs=log_lines,
            lines=len(log_lines),
            timestamp=datetime.now().isoformat()
        )

    except Exception as e:
        logger.error(f"Error getting policy logs: {e}")
        return PolicyLogsResponse(
            success=False,
            container_name=PHANTOM_CONTAINER_NAME,
            container_running=False,
            logs=[],
            lines=0,
            timestamp=datetime.now().isoformat(),
            error=str(e)
        )


@app.get("/policy/logs/stream")
async def stream_policy_logs():
    """
    Stream logs from the policy run log file in real-time using Server-Sent Events (SSE).

    This endpoint streams logs continuously using `tail -f` on the log file inside
    the positronic_phantom container. The connection stays open until the client
    disconnects.

    **Usage with curl:**
    ```
    curl -N http://localhost:5000/policy/logs/stream
    ```

    **Usage with JavaScript:**
    ```javascript
    const eventSource = new EventSource('/policy/logs/stream');
    eventSource.onmessage = (event) => console.log(event.data);
    ```
    """
    docker_cmd = get_nixos_command('docker')
    log_file = "/tmp/policy_run.log"

    def generate():
        process = None
        try:
            # Start tail -f on the log file with stdbuf for line buffering
            # stdbuf -oL forces line-buffered output to reduce latency
            process = subprocess.Popen(
                ['stdbuf', '-oL', docker_cmd, 'exec', PHANTOM_CONTAINER_NAME, 'tail', '-f', log_file],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                bufsize=0  # Unbuffered
            )

            # Stream each line as SSE
            while True:
                line = process.stdout.readline()
                if not line:
                    break
                yield f"data: {line.decode('utf-8', errors='replace').rstrip()}\n\n"

        except Exception as e:
            yield f"data: Error: {str(e)}\n\n"
        finally:
            if process:
                process.terminate()
                process.wait()

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no"  # Disable nginx buffering
        }
    )


# ============================================================================
# Phantom Orchestration Endpoints
# ============================================================================

@app.get("/phantom/status", response_model=PhantomOrchestrationStatusResponse)
async def get_phantom_status():
    """
    Get the current status of the phantom robot system.

    Returns the status of all phantom components:
    - Python policy container (positronic_control)
    - Java policy controller (phantom-policy.service)

    Also indicates whether the system is running in SHM (shared memory) mode.
    """
    result = phantom_orchestrator.get_status()
    return result


@app.post("/phantom/start", response_model=PhantomOrchestrationResponse)
async def start_phantom(request: PhantomOrchestrationRequest = PhantomOrchestrationRequest()):
    """
    Start the phantom robot system with orchestrated sequence.

    **Startup Sequence:**
    1. Configure SHM mode if requested
    2. Start Python policy container (positronic_control)
    3. Wait for Python container to initialize ROS2 nodes
    4. Start Java policy controller (phantom-policy.service)

    **Request Body:**
    - `shm` (optional, default: false): Enable shared memory DDS transport for faster inter-process communication

    **Note:** If the Java controller fails to start, the Python container will be automatically stopped.
    """
    result = phantom_orchestrator.start(shm_mode=request.shm)

    if not result["success"]:
        raise HTTPException(
            status_code=500,
            detail=result.get("error", result.get("message", "Failed to start phantom system"))
        )

    return result


@app.post("/phantom/stop", response_model=PhantomOrchestrationResponse)
async def stop_phantom():
    """
    Stop the phantom robot system with orchestrated sequence.

    **Shutdown Sequence (reverse of startup):**
    1. Stop Java policy controller
    2. Stop Python policy container
    3. Clean up SHM mode configuration
    """
    result = phantom_orchestrator.stop()

    if not result["success"]:
        raise HTTPException(
            status_code=500,
            detail=result.get("error", result.get("message", "Failed to stop phantom system"))
        )

    return result


@app.get("/phantom/logs", response_model=ServiceLogsResponse)
async def get_phantom_logs(
    service: str = Query(default=None, description="Service name: phantom-controller or phantom-controller-shm (default: auto-detect active service)"),
    lines: int = Query(default=100, description="Number of log lines to retrieve (max 1000)")
):
    """
    Get logs from the phantom controller systemd service via journalctl.

    **Query Parameters:**
    - `service`: Specific service (phantom-controller or phantom-controller-shm). If not provided, uses the active service.
    - `lines`: Number of log lines to retrieve (default 100, max 1000)

    **Example:**
    ```
    curl "http://localhost:5000/phantom/logs?service=phantom-controller&lines=100"
    ```
    """
    if lines > 1000:
        lines = 1000

    result = phantom_orchestrator.get_logs(lines=lines, service=service)

    return ServiceLogsResponse(
        service_name=result.get("service"),
        source="journalctl",
        lines=len(result.get("logs", [])),
        logs=result.get("logs", []),
        timestamp=result.get("timestamp", datetime.now().isoformat()),
        error=result.get("error"),
        message=result.get("message")
    )


@app.get("/phantom/logs/stream")
async def stream_phantom_logs(
    service: str = Query(default=None, description="Service name: phantom-controller or phantom-controller-shm (default: auto-detect active service)")
):
    """
    Stream logs from the phantom controller systemd service in real-time using Server-Sent Events (SSE).

    This endpoint streams logs continuously using `journalctl -f` on the phantom
    controller service. The connection stays open until the client disconnects.

    **Query Parameters:**
    - `service`: Specific service (phantom-controller or phantom-controller-shm). If not provided, uses the active service.

    **Usage with curl:**
    ```
    curl -N "http://localhost:5000/phantom/logs/stream"
    curl -N "http://localhost:5000/phantom/logs/stream?service=phantom-controller"
    ```

    **Usage with JavaScript:**
    ```javascript
    const eventSource = new EventSource('/phantom/logs/stream');
    eventSource.onmessage = (event) => console.log(event.data);
    ```
    """
    # Determine which service to use
    if service:
        service_name = service
    else:
        # Auto-detect active service
        status = phantom_orchestrator.get_status()
        if status.get("shm_mode"):
            service_name = "phantom-controller-shm"
        else:
            service_name = "phantom-controller"

    def generate():
        process = None
        try:
            # Start journalctl -f on the service with stdbuf for line buffering
            process = subprocess.Popen(
                ['stdbuf', '-oL', 'journalctl', '-f', '-u', service_name, '-o', 'cat', '--no-pager'],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                bufsize=0  # Unbuffered
            )

            # Stream each line as SSE
            while True:
                line = process.stdout.readline()
                if not line:
                    break
                yield f"data: {line.decode('utf-8', errors='replace').rstrip()}\n\n"

        except Exception as e:
            yield f"data: Error: {str(e)}\n\n"
        finally:
            if process:
                process.terminate()
                process.wait()

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no"  # Disable nginx buffering
        }
    )


# ============================================================================
# Java Controller Endpoints
# ============================================================================

@app.get("/java-controller/status", response_model=JavaControllerStatusResponse)
async def get_java_controller_status():
    """
    Get the current status of the Java controller system.

    Returns whether the Java controller is running and in which mode (standard or SHM).
    """
    result = java_controller_orchestrator.get_status()
    return result


@app.post("/java-controller/start", response_model=JavaControllerResponse)
async def start_java_controller(request: JavaControllerRequest = JavaControllerRequest()):
    """
    Start the Java controller via systemd service.

    **Request Body:**
    - `shm` (optional, default: false): Enable shared memory DDS transport (java-controller-shm service)

    **Examples:**
    ```bash
    # Start in standard mode
    curl -X POST http://localhost:5000/java-controller/start

    # Start in SHM mode
    curl -X POST http://localhost:5000/java-controller/start -H "Content-Type: application/json" -d '{"shm": true}'
    ```
    """
    result = java_controller_orchestrator.start(shm_mode=request.shm)

    if not result["success"]:
        raise HTTPException(
            status_code=500,
            detail=result.get("error", result.get("message", "Failed to start Java controller"))
        )

    return result


@app.post("/java-controller/stop", response_model=JavaControllerResponse)
async def stop_java_controller():
    """
    Stop the Java controller via systemd.

    Stops whichever service is currently active (java-controller or java-controller-shm).
    """
    result = java_controller_orchestrator.stop()

    if not result["success"]:
        raise HTTPException(
            status_code=500,
            detail=result.get("error", result.get("message", "Failed to stop Java controller"))
        )

    return result


@app.get("/java-controller/logs", response_model=ServiceLogsResponse)
async def get_java_controller_logs(
    service: str = Query(default=None, description="Service name: java-controller or java-controller-shm (default: auto-detect active service)"),
    lines: int = Query(default=100, description="Number of log lines to retrieve (max 1000)")
):
    """
    Get logs from the Java controller systemd service via journalctl.

    **Query Parameters:**
    - `service`: Specific service (java-controller or java-controller-shm). If not provided, uses the active service.
    - `lines`: Number of log lines to retrieve (default 100, max 1000)

    **Example:**
    ```
    curl "http://localhost:5000/java-controller/logs?service=java-controller&lines=100"
    ```
    """
    if lines > 1000:
        lines = 1000

    result = java_controller_orchestrator.get_logs(lines=lines, service=service)

    return ServiceLogsResponse(
        service_name=result.get("service_name"),
        source="journalctl",
        lines=len(result.get("logs", [])),
        logs=result.get("logs", []),
        timestamp=result.get("timestamp", datetime.now().isoformat()),
        error=result.get("error"),
        message=result.get("message")
    )


@app.get("/java-controller/logs/stream")
async def stream_java_controller_logs(
    service: str = Query(default=None, description="Service name: java-controller or java-controller-shm (default: auto-detect active service)")
):
    """
    Stream logs from the Java controller systemd service in real-time using Server-Sent Events (SSE).

    **Query Parameters:**
    - `service`: Specific service (java-controller or java-controller-shm). If not provided, uses the active service.

    **Usage with curl:**
    ```
    curl -N "http://localhost:5000/java-controller/logs/stream"
    curl -N "http://localhost:5000/java-controller/logs/stream?service=java-controller-shm"
    ```
    """
    # Determine which service to use
    if service:
        service_name = service
    else:
        # Auto-detect active service
        status = java_controller_orchestrator.get_status()
        if status.get("shm_mode"):
            service_name = "java-controller-shm"
        else:
            service_name = "java-controller"

    def generate():
        process = None
        try:
            # Start journalctl -f on the service with stdbuf for line buffering
            process = subprocess.Popen(
                ['stdbuf', '-oL', 'journalctl', '-f', '-u', service_name, '-o', 'cat', '--no-pager'],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                bufsize=0  # Unbuffered
            )

            # Stream each line as SSE
            while True:
                line = process.stdout.readline()
                if not line:
                    break
                yield f"data: {line.decode('utf-8', errors='replace').rstrip()}\n\n"

        except Exception as e:
            yield f"data: Error: {str(e)}\n\n"
        finally:
            if process:
                process.terminate()
                process.wait()

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no"  # Disable nginx buffering
        }
    )


# API compatibility endpoints for phantom orchestration (under /api prefix)
# ============================================================================
# EtherCAT Slave Info Endpoint
# ============================================================================

@app.get("/phantom/slave-info", response_model=SlaveInfoResponse)
async def get_slave_info():
    """
    Get EtherCAT slave information by running the run-slaveInfo script.

    Returns the output from the EtherCAT slave discovery tool, which shows
    connected EtherCAT slaves and their status.
    """
    try:
        script_path = os.path.join(PHANTOM_SCRIPT_DIRECTORY, "run-slaveInfo")

        if not os.path.exists(script_path):
            return SlaveInfoResponse(
                success=False,
                output=[],
                timestamp=datetime.now().isoformat(),
                error=f"Script not found: {script_path}"
            )

        # Run the script with explicit bash path for NixOS
        bash_path = "/run/current-system/sw/bin/bash"

        # Set up environment - PHANTOM_SRC_HOME is required by run-slaveInfo
        env = os.environ.copy()
        env["HOME"] = HOME_DIR
        env["PATH"] = "/run/current-system/sw/bin:" + env.get("PATH", "")
        env["PHANTOM_SRC_HOME"] = PHANTOM_SRC_HOME
        env["GIT_CONFIG_COUNT"] = "1"
        env["GIT_CONFIG_KEY_0"] = "safe.directory"
        env["GIT_CONFIG_VALUE_0"] = PHANTOM_SCRIPT_DIRECTORY

        result = subprocess.run(
            [bash_path, script_path],
            cwd=PHANTOM_SCRIPT_DIRECTORY,
            capture_output=True,
            text=True,
            timeout=60,  # slaveInfo may take longer due to nix develop
            env=env
        )

        # Combine stdout and stderr, split into lines
        output = result.stdout + result.stderr
        output_lines = [line for line in output.strip().split('\n') if line]

        return SlaveInfoResponse(
            success=result.returncode == 0,
            output=output_lines,
            timestamp=datetime.now().isoformat(),
            error=None if result.returncode == 0 else f"Script exited with code {result.returncode}"
        )

    except subprocess.TimeoutExpired:
        return SlaveInfoResponse(
            success=False,
            output=[],
            timestamp=datetime.now().isoformat(),
            error="Script execution timed out after 60 seconds"
        )
    except Exception as e:
        logger.error(f"Error running slave info script: {e}")
        return SlaveInfoResponse(
            success=False,
            output=[],
            timestamp=datetime.now().isoformat(),
            error=str(e)
        )


def _get_compose_env() -> dict:
    """Get environment variables required for docker compose."""
    env = os.environ.copy()

    # Set REPO_ROOT
    env['REPO_ROOT'] = POSITRONIC_CONTROL_PATH

    # Read VERSION from file
    version_file = os.path.join(POSITRONIC_CONTROL_PATH, 'VERSION')
    version = '0.2.42'  # default
    if os.path.exists(version_file):
        with open(version_file, 'r') as f:
            for line in f:
                if line.startswith('VERSION='):
                    version = line.strip().split('=')[1]
                    break
    env['VERSION'] = version

    # Set CUDA version and image variables (for development compose)
    cuda_version = env.get('CUDA_VERSION', 'cu128')
    env['CUDA_VERSION'] = cuda_version
    env['PHANTOM_IMAGE'] = 'foundationbot/phantom-cuda'
    env['PHANTOM_IMAGE_TAG'] = f'{version}-{cuda_version}'

    # Set X11 forwarding variables
    env['XSOCK'] = '/tmp/.X11-unix'
    env['XAUTH'] = env.get('XAUTHORITY', '/tmp/.Xauthority')
    env['DISPLAY'] = env.get('DISPLAY', ':0')

    # Set cache directories (from RobotConfig)
    env['TORCH_HOME'] = env.get('TORCH_HOME', TORCH_HOME)
    env['HF_HUB_CACHE'] = env.get('HF_HUB_CACHE', HF_HUB_CACHE)

    # Set PHANTOM_MODELS for the container - always use /root/models (the host path that gets
    # volume-mounted into the container), not the host's PHANTOM_MODELS which may point to
    # an immutable /nix/store path that doesn't reflect live model changes
    env['PHANTOM_MODELS'] = '/root/models'

    return env


# ============================================================================
# Joystick Endpoints
# ============================================================================


@app.get("/joystick/status", response_model=JoystickStatusResponse)
async def joystick_status():
    """
    Check if a Sony joystick is currently connected.

    Runs `lsusb | grep Sony` to detect connected Sony devices.
    Also returns the USB/IP port number if connected.
    """
    try:
        lsusb_cmd = get_nixos_command('lsusb')
        result = subprocess.run(
            [lsusb_cmd],
            capture_output=True,
            text=True,
            timeout=10
        )

        lsusb_output = result.stdout
        sony_lines = [line for line in lsusb_output.split('\n') if 'Sony' in line]
        connected = len(sony_lines) > 0

        # Get port number if connected
        port = None
        if connected:
            try:
                import re
                usbip_cmd = get_nixos_command('usbip')
                port_result = subprocess.run(
                    [usbip_cmd, 'port'],
                    capture_output=True,
                    text=True,
                    timeout=10
                )
                port_output = port_result.stdout + port_result.stderr
                # Parse output to find port - format: "Port 00: ..."
                port_pattern = re.compile(r'Port\s+(\d+):')
                for line in port_output.split('\n'):
                    match = port_pattern.match(line)
                    if match:
                        port = match.group(1)
                        # Take the last port found (most recently attached)
            except Exception as port_err:
                logger.warning(f"Could not get USB/IP port: {port_err}")

        return JoystickStatusResponse(
            success=True,
            connected=connected,
            device_info=sony_lines[0] if sony_lines else None,
            port=port,
            timestamp=datetime.now().isoformat()
        )

    except subprocess.TimeoutExpired:
        return JoystickStatusResponse(
            success=False,
            connected=False,
            timestamp=datetime.now().isoformat(),
            error="lsusb command timed out"
        )
    except Exception as e:
        logger.error(f"Error checking joystick status: {e}")
        return JoystickStatusResponse(
            success=False,
            connected=False,
            timestamp=datetime.now().isoformat(),
            error=str(e)
        )


# =============================================================================
# ADB Endpoints
# =============================================================================

@app.get("/adb/devices", response_model=AdbDevicesResponse)
async def adb_devices():
    """
    List connected ADB devices.

    Runs `adb devices` to list all connected Android devices.
    """
    try:
        adb_cmd = get_nixos_command('adb')
        result = subprocess.run(
            [adb_cmd, 'devices'],
            capture_output=True,
            text=True,
            timeout=10
        )

        raw_output = result.stdout
        devices = []

        # Parse adb devices output
        # Format: "serial\tstate"
        lines = raw_output.strip().split('\n')
        for line in lines[1:]:  # Skip header line "List of devices attached"
            line = line.strip()
            if line and '\t' in line:
                parts = line.split('\t')
                if len(parts) >= 2:
                    devices.append(AdbDevice(
                        serial=parts[0],
                        state=parts[1]
                    ))

        return AdbDevicesResponse(
            success=True,
            devices=devices,
            raw_output=raw_output,
            timestamp=datetime.now().isoformat()
        )

    except subprocess.TimeoutExpired:
        return AdbDevicesResponse(
            success=False,
            devices=[],
            raw_output="",
            timestamp=datetime.now().isoformat(),
            error="adb devices timed out"
        )
    except FileNotFoundError:
        return AdbDevicesResponse(
            success=False,
            devices=[],
            raw_output="",
            timestamp=datetime.now().isoformat(),
            error="adb command not found - is ADB installed?"
        )
    except Exception as e:
        logger.error(f"Error running adb devices: {e}")
        return AdbDevicesResponse(
            success=False,
            devices=[],
            raw_output="",
            timestamp=datetime.now().isoformat(),
            error=str(e)
        )


@app.post("/adb/reverse", response_model=AdbReverseResponse)
async def adb_reverse(request: AdbReverseRequest):
    """
    Set up ADB reverse port forwarding.

    Runs: adb reverse tcp:<port> tcp:<port>
    This exposes a port from the host machine to the connected Android device.

    **Request Body:**
    - `port`: Port number to expose (1-65535)
    - `serial`: (Optional) Target device serial number. If not specified, uses the first connected device.
    """
    try:
        port = request.port

        # Build the command
        adb_cmd = get_nixos_command('adb')
        cmd = [adb_cmd]
        if request.serial:
            cmd.extend(['-s', request.serial])
        cmd.extend(['reverse', f'tcp:{port}', f'tcp:{port}'])

        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=10
        )

        output = result.stdout + result.stderr

        if result.returncode == 0:
            return AdbReverseResponse(
                success=True,
                message=f"Successfully set up reverse port forwarding for port {port}",
                port=port,
                serial=request.serial,
                output=output.strip(),
                timestamp=datetime.now().isoformat()
            )
        else:
            return AdbReverseResponse(
                success=False,
                message="Failed to set up reverse port forwarding",
                port=port,
                serial=request.serial,
                output=output.strip(),
                timestamp=datetime.now().isoformat(),
                error=f"adb reverse exited with code {result.returncode}"
            )

    except subprocess.TimeoutExpired:
        return AdbReverseResponse(
            success=False,
            message="Command timed out",
            port=request.port,
            serial=request.serial,
            output="",
            timestamp=datetime.now().isoformat(),
            error="adb reverse timed out"
        )
    except FileNotFoundError:
        return AdbReverseResponse(
            success=False,
            message="ADB not found",
            port=request.port,
            serial=request.serial,
            output="",
            timestamp=datetime.now().isoformat(),
            error="adb command not found - is ADB installed?"
        )
    except Exception as e:
        logger.error(f"Error running adb reverse: {e}")
        return AdbReverseResponse(
            success=False,
            message="Error setting up reverse port",
            port=request.port,
            serial=request.serial,
            output="",
            timestamp=datetime.now().isoformat(),
            error=str(e)
        )


# =============================================================================
# Docker Endpoints
# =============================================================================

@app.get("/docker/containers", response_model=DockerContainersResponse)
async def docker_containers(name: Optional[str] = None, all: bool = False):
    """
    List Docker containers.

    **Query Parameters:**
    - `name`: (Optional) Filter containers by name (grep-style matching)
    - `all`: (Optional) Include stopped containers (default: false, only running)
    """
    try:
        # Build command: docker ps --format with JSON-like output
        docker_cmd = get_nixos_command('docker')
        cmd = [docker_cmd, 'ps', '--format', '{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.State}}\t{{.Ports}}\t{{.CreatedAt}}']
        if all:
            cmd.insert(2, '-a')

        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=30
        )

        if result.returncode != 0:
            return DockerContainersResponse(
                success=False,
                containers=[],
                filter=name,
                include_stopped=all,
                timestamp=datetime.now().isoformat(),
                error=result.stderr.strip() or f"docker ps exited with code {result.returncode}"
            )

        containers = []
        lines = result.stdout.strip().split('\n')

        for line in lines:
            if not line.strip():
                continue

            parts = line.split('\t')
            if len(parts) >= 5:
                container_name = parts[1]

                # Apply name filter if provided
                if name and name.lower() not in container_name.lower():
                    continue

                containers.append(DockerContainer(
                    id=parts[0],
                    name=container_name,
                    image=parts[2],
                    status=parts[3],
                    state=parts[4],
                    ports=parts[5] if len(parts) > 5 else "",
                    created=parts[6] if len(parts) > 6 else ""
                ))

        return DockerContainersResponse(
            success=True,
            containers=containers,
            filter=name,
            include_stopped=all,
            timestamp=datetime.now().isoformat()
        )

    except subprocess.TimeoutExpired:
        return DockerContainersResponse(
            success=False,
            containers=[],
            filter=name,
            include_stopped=all,
            timestamp=datetime.now().isoformat(),
            error="docker ps timed out"
        )
    except FileNotFoundError:
        return DockerContainersResponse(
            success=False,
            containers=[],
            filter=name,
            include_stopped=all,
            timestamp=datetime.now().isoformat(),
            error="docker command not found - is Docker installed?"
        )
    except Exception as e:
        logger.error(f"Error running docker ps: {e}")
        return DockerContainersResponse(
            success=False,
            containers=[],
            filter=name,
            include_stopped=all,
            timestamp=datetime.now().isoformat(),
            error=str(e)
        )


@app.get("/docker/containers/{container_name}", response_model=DockerContainersResponse)
async def docker_container_by_name(container_name: str):
    """
    Get a specific Docker container by name.

    **Path Parameters:**
    - `container_name`: Container name (exact match)
    """
    try:
        docker_cmd = get_nixos_command('docker')
        cmd = [docker_cmd, 'ps', '-a', '--filter', f'name=^{container_name}$',
               '--format', '{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.State}}\t{{.Ports}}\t{{.CreatedAt}}']

        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)

        if result.returncode != 0:
            return DockerContainersResponse(
                success=False,
                containers=[],
                filter=container_name,
                include_stopped=True,
                timestamp=datetime.now().isoformat(),
                error=result.stderr.strip() or f"docker ps exited with code {result.returncode}"
            )

        containers = []
        lines = result.stdout.strip().split('\n')

        for line in lines:
            if not line.strip():
                continue
            parts = line.split('\t')
            if len(parts) >= 5:
                containers.append(DockerContainer(
                    id=parts[0],
                    name=parts[1],
                    image=parts[2],
                    status=parts[3],
                    state=parts[4],
                    ports=parts[5] if len(parts) > 5 else "",
                    created=parts[6] if len(parts) > 6 else ""
                ))

        return DockerContainersResponse(
            success=True,
            containers=containers,
            filter=container_name,
            include_stopped=True,
            timestamp=datetime.now().isoformat()
        )

    except Exception as e:
        logger.error(f"Error getting container {container_name}: {e}")
        return DockerContainersResponse(
            success=False,
            containers=[],
            filter=container_name,
            include_stopped=True,
            timestamp=datetime.now().isoformat(),
            error=str(e)
        )


@app.post("/docker/containers/{container_name}/start", response_model=DockerOperationResponse)
async def docker_container_start(container_name: str):
    """
    Start a Docker container.

    **Path Parameters:**
    - `container_name`: Container name or ID
    """
    try:
        docker_cmd = get_nixos_command('docker')
        result = subprocess.run(
            [docker_cmd, 'start', container_name],
            capture_output=True,
            text=True,
            timeout=60
        )

        output = (result.stdout + result.stderr).strip()

        if result.returncode != 0:
            return DockerOperationResponse(
                success=False,
                operation="start",
                container=container_name,
                message=f"Failed to start container {container_name}",
                output=output,
                timestamp=datetime.now().isoformat(),
                error=output
            )

        return DockerOperationResponse(
            success=True,
            operation="start",
            container=container_name,
            message=f"Container {container_name} started successfully",
            output=output,
            timestamp=datetime.now().isoformat()
        )

    except Exception as e:
        logger.error(f"Error starting container {container_name}: {e}")
        return DockerOperationResponse(
            success=False,
            operation="start",
            container=container_name,
            message=f"Error starting container {container_name}",
            output="",
            timestamp=datetime.now().isoformat(),
            error=str(e)
        )


@app.post("/docker/containers/{container_name}/stop", response_model=DockerOperationResponse)
async def docker_container_stop(container_name: str):
    """
    Stop a Docker container.

    **Path Parameters:**
    - `container_name`: Container name or ID
    """
    try:
        docker_cmd = get_nixos_command('docker')
        result = subprocess.run(
            [docker_cmd, 'stop', container_name],
            capture_output=True,
            text=True,
            timeout=60
        )

        output = (result.stdout + result.stderr).strip()

        if result.returncode != 0:
            return DockerOperationResponse(
                success=False,
                operation="stop",
                container=container_name,
                message=f"Failed to stop container {container_name}",
                output=output,
                timestamp=datetime.now().isoformat(),
                error=output
            )

        return DockerOperationResponse(
            success=True,
            operation="stop",
            container=container_name,
            message=f"Container {container_name} stopped successfully",
            output=output,
            timestamp=datetime.now().isoformat()
        )

    except Exception as e:
        logger.error(f"Error stopping container {container_name}: {e}")
        return DockerOperationResponse(
            success=False,
            operation="stop",
            container=container_name,
            message=f"Error stopping container {container_name}",
            output="",
            timestamp=datetime.now().isoformat(),
            error=str(e)
        )


@app.post("/docker/containers/{container_name}/restart", response_model=DockerOperationResponse)
async def docker_container_restart(container_name: str):
    """
    Restart a Docker container.

    **Path Parameters:**
    - `container_name`: Container name or ID
    """
    try:
        docker_cmd = get_nixos_command('docker')
        result = subprocess.run(
            [docker_cmd, 'restart', container_name],
            capture_output=True,
            text=True,
            timeout=120
        )

        output = (result.stdout + result.stderr).strip()

        if result.returncode != 0:
            return DockerOperationResponse(
                success=False,
                operation="restart",
                container=container_name,
                message=f"Failed to restart container {container_name}",
                output=output,
                timestamp=datetime.now().isoformat(),
                error=output
            )

        return DockerOperationResponse(
            success=True,
            operation="restart",
            container=container_name,
            message=f"Container {container_name} restarted successfully",
            output=output,
            timestamp=datetime.now().isoformat()
        )

    except Exception as e:
        logger.error(f"Error restarting container {container_name}: {e}")
        return DockerOperationResponse(
            success=False,
            operation="restart",
            container=container_name,
            message=f"Error restarting container {container_name}",
            output="",
            timestamp=datetime.now().isoformat(),
            error=str(e)
        )


@app.get("/docker/containers/{container_name}/cpuset", response_model=DockerCpusetResponse)
async def docker_container_cpuset_get(container_name: str):
    """
    Get current CPU affinity (cpuset) for a Docker container.

    **Path Parameters:**
    - `container_name`: Container name or ID

    **Returns:**
    - `cpuset`: Current cpuset-cpus value (empty string if not set)
    """
    try:
        docker_cmd = get_nixos_command('docker')

        result = subprocess.run(
            [docker_cmd, 'inspect', '--format={{.HostConfig.CpusetCpus}}', container_name],
            capture_output=True,
            text=True,
            timeout=10
        )

        if result.returncode != 0:
            return DockerCpusetResponse(
                success=False,
                container=container_name,
                cpuset="",
                timestamp=datetime.now().isoformat(),
                error=result.stderr.strip()
            )

        return DockerCpusetResponse(
            success=True,
            container=container_name,
            cpuset=result.stdout.strip(),
            timestamp=datetime.now().isoformat()
        )

    except Exception as e:
        logger.error(f"Error getting cpuset for container {container_name}: {e}")
        return DockerCpusetResponse(
            success=False,
            container=container_name,
            cpuset="",
            timestamp=datetime.now().isoformat(),
            error=str(e)
        )


@app.post("/docker/containers/{container_name}/cpuset", response_model=DockerOperationResponse)
async def docker_container_cpuset_set(container_name: str, request: DockerCpusetRequest = None):
    """
    Set CPU affinity (cpuset) for a Docker container.

    **Path Parameters:**
    - `container_name`: Container name or ID

    **Request Body (optional):**
    - `cpus`: CPU cores to assign (default: "0-14", format: "0-14" or "0,2,4,6")
    """
    cpus = request.cpus if request else "0-14"

    try:
        docker_cmd = get_nixos_command('docker')

        # Set cpuset (no sudo - user should be in docker group)
        result = subprocess.run(
            [docker_cmd, 'update', f'--cpuset-cpus={cpus}', container_name],
            capture_output=True,
            text=True,
            timeout=30
        )

        if result.returncode != 0:
            return DockerOperationResponse(
                success=False,
                operation="cpuset",
                container=container_name,
                message=f"Failed to set cpuset for {container_name}",
                output=result.stderr,
                timestamp=datetime.now().isoformat(),
                error=result.stderr
            )

        # Verify by inspecting
        inspect_result = subprocess.run(
            [docker_cmd, 'inspect', '--format={{.HostConfig.CpusetCpus}}', container_name],
            capture_output=True,
            text=True,
            timeout=10
        )
        actual_cpuset = inspect_result.stdout.strip() if inspect_result.returncode == 0 else cpus

        return DockerOperationResponse(
            success=True,
            operation="cpuset",
            container=container_name,
            message=f"Container {container_name} cpuset set to {actual_cpuset}",
            output=actual_cpuset,
            timestamp=datetime.now().isoformat()
        )

    except Exception as e:
        logger.error(f"Error setting cpuset for container {container_name}: {e}")
        return DockerOperationResponse(
            success=False,
            operation="cpuset",
            container=container_name,
            message=f"Error setting cpuset for {container_name}",
            output="",
            timestamp=datetime.now().isoformat(),
            error=str(e)
        )


@app.get("/docker/containers/{container_name}/logs", response_model=DockerLogsResponse)
async def docker_container_logs(
    container_name: str,
    lines: int = Query(default=100, description="Number of log lines to retrieve (max 1000)"),
    since: str = Query(default=None, description="Show logs since timestamp (e.g., '2021-01-01T00:00:00' or '10m')")
):
    """
    Get logs from a Docker container.

    **Path Parameters:**
    - `container_name`: Container name or ID

    **Query Parameters:**
    - `lines`: Number of log lines (default 100, max 1000)
    - `since`: Show logs since timestamp or duration (e.g., '10m', '1h', '2021-01-01')
    """
    try:
        if lines > 1000:
            lines = 1000

        docker_cmd = get_nixos_command('docker')
        cmd = [docker_cmd, 'logs', '--tail', str(lines)]

        if since:
            cmd.extend(['--since', since])

        cmd.append(container_name)

        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)

        # Docker logs outputs to stderr for container stderr
        output = result.stdout + result.stderr
        log_lines = output.strip().split('\n') if output.strip() else []

        if result.returncode != 0 and not log_lines:
            return DockerLogsResponse(
                success=False,
                container=container_name,
                logs=[],
                lines=0,
                timestamp=datetime.now().isoformat(),
                error=result.stderr.strip() or f"docker logs exited with code {result.returncode}"
            )

        return DockerLogsResponse(
            success=True,
            container=container_name,
            logs=log_lines,
            lines=len(log_lines),
            timestamp=datetime.now().isoformat()
        )

    except Exception as e:
        logger.error(f"Error getting logs for container {container_name}: {e}")
        return DockerLogsResponse(
            success=False,
            container=container_name,
            logs=[],
            lines=0,
            timestamp=datetime.now().isoformat(),
            error=str(e)
        )


@app.get("/docker/containers/{container_name}/logs/stream")
async def stream_docker_container_logs(container_name: str):
    """
    Stream logs from a Docker container in real-time using Server-Sent Events (SSE).

    **Path Parameters:**
    - `container_name`: Container name or ID

    **Returns:**
    - SSE stream with log lines as `data: <log_line>` events
    - Connect with EventSource or curl: `curl -N http://localhost:5000/docker/containers/positronic_phantom/logs/stream`
    """
    docker_cmd = get_nixos_command('docker')

    def generate():
        try:
            # Use docker logs -f for streaming
            process = subprocess.Popen(
                ['stdbuf', '-oL', docker_cmd, 'logs', '-f', container_name],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                bufsize=0
            )

            while True:
                line = process.stdout.readline()
                if not line:
                    # Check if process has ended
                    if process.poll() is not None:
                        break
                    continue

                decoded_line = line.decode('utf-8', errors='replace').rstrip()
                yield f"data: {decoded_line}\n\n"

        except Exception as e:
            yield f"data: Error streaming logs: {str(e)}\n\n"
        finally:
            if 'process' in locals() and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no"
        }
    )


@app.post("/docker/pull", response_model=DockerOperationResponse)
async def docker_pull(image: str = Query(..., description="Image name to pull (e.g., 'nginx:latest')")):
    """
    Pull a Docker image.

    **Query Parameters:**
    - `image`: Image name to pull (e.g., 'nginx:latest', 'ubuntu:22.04')
    """
    try:
        docker_cmd = get_nixos_command('docker')
        result = subprocess.run(
            [docker_cmd, 'pull', image],
            capture_output=True,
            text=True,
            timeout=600  # 10 minutes for large images
        )

        output = (result.stdout + result.stderr).strip()

        if result.returncode != 0:
            return DockerOperationResponse(
                success=False,
                operation="pull",
                container=image,
                message=f"Failed to pull image {image}",
                output=output,
                timestamp=datetime.now().isoformat(),
                error=output
            )

        return DockerOperationResponse(
            success=True,
            operation="pull",
            container=image,
            message=f"Image {image} pulled successfully",
            output=output,
            timestamp=datetime.now().isoformat()
        )

    except subprocess.TimeoutExpired:
        return DockerOperationResponse(
            success=False,
            operation="pull",
            container=image,
            message=f"Timeout pulling image {image}",
            output="",
            timestamp=datetime.now().isoformat(),
            error="Pull operation timed out after 10 minutes"
        )
    except Exception as e:
        logger.error(f"Error pulling image {image}: {e}")
        return DockerOperationResponse(
            success=False,
            operation="pull",
            container=image,
            message=f"Error pulling image {image}",
            output="",
            timestamp=datetime.now().isoformat(),
            error=str(e)
        )


# =============================================================================
# Docker Compose Endpoints
# =============================================================================

def _parse_port_mappings(raw_ports: str) -> str:
    """
    Parse Docker port mappings to extract host:container pairs.

    Input: "0.0.0.0:9000->9000/tcp, [::]:9000->9000/tcp, 8080->80/tcp"
    Output: "9000:9000, 8080:80"
    """
    if not raw_ports:
        return ""

    import re
    port_pairs = set()

    # Match patterns like "0.0.0.0:9000->9000/tcp" or "9000->9000/tcp"
    # Capture host_port->container_port
    pattern = r'(?:\d+\.\d+\.\d+\.\d+:|(?:\[::\]:))?(\d+)->(\d+)(?:/\w+)?'

    for match in re.finditer(pattern, raw_ports):
        host_port = match.group(1)
        container_port = match.group(2)
        port_pairs.add(f"{host_port}:{container_port}")

    return ", ".join(sorted(port_pairs))


def _get_compose_project(project: str) -> Optional[dict]:
    """Get compose project config by name."""
    return COMPOSE_PROJECTS.get(project)


def _run_compose_command(project_config: dict, args: List[str], timeout: int = 120, profile: str = None) -> subprocess.CompletedProcess:
    """Run a docker compose command in the project directory."""
    docker_cmd = get_nixos_command('docker')
    cmd = [docker_cmd, 'compose', '-f', project_config['file']]

    # Add profile if specified
    if profile:
        cmd.extend(['--profile', profile])

    cmd.extend(args)

    return subprocess.run(
        cmd,
        cwd=project_config['path'],
        capture_output=True,
        text=True,
        timeout=timeout
    )


def _run_systemctl_command(service: str, action: str, timeout: int = 60) -> subprocess.CompletedProcess:
    """Run a systemctl command for a service."""
    systemctl_cmd = get_nixos_command('systemctl')
    sudo_cmd = get_nixos_command('sudo')
    cmd = [sudo_cmd, systemctl_cmd, action, service]

    return subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=timeout
    )


def _get_systemctl_status(service: str) -> dict:
    """Get systemctl service status."""
    systemctl_cmd = get_nixos_command('systemctl')
    result = subprocess.run(
        [systemctl_cmd, 'is-active', service],
        capture_output=True,
        text=True,
        timeout=10
    )
    is_active = result.stdout.strip() == 'active'

    # Get more detailed status
    result = subprocess.run(
        [systemctl_cmd, 'status', service, '--no-pager'],
        capture_output=True,
        text=True,
        timeout=10
    )

    return {
        'is_active': is_active,
        'status_output': result.stdout + result.stderr
    }


@app.get("/docker-compose/projects", response_model=ComposeProjectsResponse)
async def compose_projects():
    """
    List all configured Docker Compose projects.

    Returns the available project aliases that can be used with other compose endpoints.
    """
    projects = [
        ComposeProjectInfo(name=name, path=config['path'], file=config['file'])
        for name, config in COMPOSE_PROJECTS.items()
    ]

    return ComposeProjectsResponse(
        success=True,
        projects=projects,
        timestamp=datetime.now().isoformat()
    )


@app.get("/docker-compose/status", response_model=ComposeStatusResponse)
async def compose_status(project: str):
    """
    Get status of services in a Docker Compose project.

    **Query Parameters:**
    - `project`: Project name (e.g., 'operator-ui', 'teleop')
    """
    project_config = _get_compose_project(project)
    if not project_config:
        return ComposeStatusResponse(
            success=False,
            project=project,
            services=[],
            timestamp=datetime.now().isoformat(),
            error=f"Unknown project: {project}. Available: {list(COMPOSE_PROJECTS.keys())}"
        )

    try:
        # docker compose ps --format with custom output
        result = _run_compose_command(
            project_config,
            ['ps', '--format', '{{.Name}}\t{{.Status}}\t{{.Health}}\t{{.Ports}}\t{{.Image}}'],
            timeout=30
        )

        services = []
        if result.returncode == 0 and result.stdout.strip():
            # Get container names for cpuset lookup
            container_names = []
            for line in result.stdout.strip().split('\n'):
                if line.strip():
                    parts = line.split('\t')
                    if len(parts) >= 1:
                        container_names.append(parts[0])

            # Fetch actual runtime CPU affinity from /proc for each container
            cpuset_map = {}
            if container_names:
                docker_cmd = get_nixos_command('docker')
                # Get container PIDs
                inspect_result = subprocess.run(
                    [docker_cmd, 'inspect', '--format', '{{.Name}}\t{{.State.Pid}}'] + container_names,
                    capture_output=True,
                    text=True,
                    timeout=10
                )
                if inspect_result.returncode == 0:
                    for inspect_line in inspect_result.stdout.strip().split('\n'):
                        if '\t' in inspect_line:
                            name, pid = inspect_line.split('\t', 1)
                            name = name.lstrip('/')
                            if pid and pid != '0':
                                # Read actual CPU affinity from /proc/<pid>/status
                                try:
                                    with open(f'/proc/{pid}/status', 'r') as f:
                                        for line in f:
                                            if line.startswith('Cpus_allowed_list:'):
                                                cpuset_map[name] = line.split(':', 1)[1].strip()
                                                break
                                except (FileNotFoundError, PermissionError):
                                    cpuset_map[name] = ""

            for line in result.stdout.strip().split('\n'):
                if not line.strip():
                    continue
                parts = line.split('\t')
                if len(parts) >= 2:
                    # Parse ports to extract host:container pairs
                    raw_ports = parts[3] if len(parts) > 3 else ""
                    parsed_ports = _parse_port_mappings(raw_ports)
                    container_name = parts[0]

                    services.append(ComposeService(
                        name=container_name,
                        status=parts[1],
                        health=parts[2] if len(parts) > 2 and parts[2] else None,
                        ports=parsed_ports,
                        image=parts[4] if len(parts) > 4 else "",
                        cpuset=cpuset_map.get(container_name, "")
                    ))

        return ComposeStatusResponse(
            success=True,
            project=project,
            services=services,
            timestamp=datetime.now().isoformat()
        )

    except subprocess.TimeoutExpired:
        return ComposeStatusResponse(
            success=False,
            project=project,
            services=[],
            timestamp=datetime.now().isoformat(),
            error="docker compose ps timed out"
        )
    except Exception as e:
        logger.error(f"Error getting compose status: {e}")
        return ComposeStatusResponse(
            success=False,
            project=project,
            services=[],
            timestamp=datetime.now().isoformat(),
            error=str(e)
        )


@app.post("/docker-compose/up", response_model=ComposeOperationResponse)
async def compose_up(request: ComposeOperationRequest):
    """
    Start Docker Compose services.

    **Request Body:**
    - `project`: Project name (e.g., 'operator-ui')
    - `services`: (Optional) Specific services to start (e.g., ['vr-web'])
    - `pull`: (Optional) Pull latest images before starting (default: false)
    - `profile`: (Optional) Docker Compose profile to use (e.g., 'teleop')

    If the project has a systemd_service configured and no profile/services specified,
    uses systemctl start instead of docker compose.

    **Example for VR-Web with teleop profile:**
    ```json
    {
        "project": "operator-ui",
        "profile": "teleop",
        "services": ["vr-web"]
    }
    ```
    """
    project_config = _get_compose_project(request.project)
    if not project_config:
        return ComposeOperationResponse(
            success=False,
            project=request.project,
            operation="up",
            message="Unknown project",
            timestamp=datetime.now().isoformat(),
            error=f"Unknown project: {request.project}. Available: {list(COMPOSE_PROJECTS.keys())}"
        )

    # Check if this project uses systemd
    systemd_service = project_config.get('systemd_service')

    try:
        output_parts = []

        # Pull images first if requested (always use docker compose for pull)
        if request.pull:
            pull_args = ['pull']
            if request.services:
                pull_args.extend(request.services)

            pull_result = _run_compose_command(project_config, pull_args, timeout=300, profile=request.profile)
            output_parts.append(f"=== Pull ===\n{pull_result.stdout}{pull_result.stderr}")

            if pull_result.returncode != 0:
                return ComposeOperationResponse(
                    success=False,
                    project=request.project,
                    operation="up",
                    message="Failed to pull images",
                    output='\n'.join(output_parts),
                    services=request.services,
                    timestamp=datetime.now().isoformat(),
                    error=f"docker compose pull exited with code {pull_result.returncode}"
                )

        # Start services - use systemctl if configured (but not if profile or specific services requested)
        if systemd_service and not request.services and not request.profile:
            # Use systemctl for systemd-managed projects (only if no specific services or profile requested)
            result = _run_systemctl_command(systemd_service, 'start', timeout=120)
            output_parts.append(f"=== systemctl start {systemd_service} ===\n{result.stdout}{result.stderr}")
        else:
            # Use docker compose directly
            up_args = ['up', '-d']
            if request.services:
                up_args.extend(request.services)

            result = _run_compose_command(project_config, up_args, timeout=120, profile=request.profile)
            output_parts.append(f"=== Up ===\n{result.stdout}{result.stderr}")

        output = '\n'.join(output_parts)

        if result.returncode == 0:
            method = f"systemctl ({systemd_service})" if (systemd_service and not request.services and not request.profile) else "docker compose"
            profile_info = f" (profile: {request.profile})" if request.profile else ""
            return ComposeOperationResponse(
                success=True,
                project=request.project,
                operation="up",
                message=f"Services started successfully via {method}{profile_info}{' (with fresh pull)' if request.pull else ''}",
                output=output,
                services=request.services,
                timestamp=datetime.now().isoformat()
            )
        else:
            return ComposeOperationResponse(
                success=False,
                project=request.project,
                operation="up",
                message="Failed to start services",
                output=output,
                services=request.services,
                timestamp=datetime.now().isoformat(),
                error=f"Command exited with code {result.returncode}"
            )

    except subprocess.TimeoutExpired:
        return ComposeOperationResponse(
            success=False,
            project=request.project,
            operation="up",
            message="Command timed out",
            services=request.services,
            timestamp=datetime.now().isoformat(),
            error="Command timed out"
        )
    except Exception as e:
        logger.error(f"Error running compose up: {e}")
        return ComposeOperationResponse(
            success=False,
            project=request.project,
            operation="up",
            message="Error starting services",
            services=request.services,
            timestamp=datetime.now().isoformat(),
            error=str(e)
        )


@app.post("/docker-compose/down", response_model=ComposeOperationResponse)
async def compose_down(request: ComposeOperationRequest):
    """
    Stop and remove Docker Compose services.

    **Request Body:**
    - `project`: Project name (e.g., 'operator-ui', 'teleop')
    - `remove_volumes`: (Optional) Remove volumes (default: false)

    If the project has a systemd_service configured, uses systemctl stop instead.
    """
    project_config = _get_compose_project(request.project)
    if not project_config:
        return ComposeOperationResponse(
            success=False,
            project=request.project,
            operation="down",
            message="Unknown project",
            timestamp=datetime.now().isoformat(),
            error=f"Unknown project: {request.project}. Available: {list(COMPOSE_PROJECTS.keys())}"
        )

    # Check if this project uses systemd
    systemd_service = project_config.get('systemd_service')

    try:
        if systemd_service:
            # Use systemctl for systemd-managed projects
            result = _run_systemctl_command(systemd_service, 'stop', timeout=60)
            output = f"=== systemctl stop {systemd_service} ===\n{result.stdout}{result.stderr}"
            method = f"systemctl ({systemd_service})"
        else:
            # Use docker compose directly
            down_args = ['down']
            if request.remove_volumes:
                down_args.append('-v')

            result = _run_compose_command(project_config, down_args, timeout=60)
            output = result.stdout + result.stderr
            method = "docker compose"

        if result.returncode == 0:
            return ComposeOperationResponse(
                success=True,
                project=request.project,
                operation="down",
                message=f"Services stopped via {method}{' (volumes removed)' if request.remove_volumes and not systemd_service else ''}",
                output=output,
                timestamp=datetime.now().isoformat()
            )
        else:
            return ComposeOperationResponse(
                success=False,
                project=request.project,
                operation="down",
                message="Failed to stop services",
                output=output,
                timestamp=datetime.now().isoformat(),
                error=f"Command exited with code {result.returncode}"
            )

    except subprocess.TimeoutExpired:
        return ComposeOperationResponse(
            success=False,
            project=request.project,
            operation="down",
            message="Command timed out",
            timestamp=datetime.now().isoformat(),
            error="Command timed out"
        )
    except Exception as e:
        logger.error(f"Error running compose down: {e}")
        return ComposeOperationResponse(
            success=False,
            project=request.project,
            operation="down",
            message="Error stopping services",
            timestamp=datetime.now().isoformat(),
            error=str(e)
        )


@app.post("/docker-compose/stop", response_model=ComposeOperationResponse)
async def compose_stop(request: ComposeOperationRequest):
    """
    Stop Docker Compose services without removing them.

    **Request Body:**
    - `project`: Project name (e.g., 'operator-ui', 'teleop')
    - `services`: (Optional) Specific services to stop

    If the project has a systemd_service configured, uses systemctl stop instead.
    """
    project_config = _get_compose_project(request.project)
    if not project_config:
        return ComposeOperationResponse(
            success=False,
            project=request.project,
            operation="stop",
            message="Unknown project",
            timestamp=datetime.now().isoformat(),
            error=f"Unknown project: {request.project}. Available: {list(COMPOSE_PROJECTS.keys())}"
        )

    # Check if this project uses systemd
    systemd_service = project_config.get('systemd_service')

    try:
        if systemd_service and not request.services:
            # Use systemctl for systemd-managed projects (only if no specific services requested)
            result = _run_systemctl_command(systemd_service, 'stop', timeout=60)
            output = f"=== systemctl stop {systemd_service} ===\n{result.stdout}{result.stderr}"
            method = f"systemctl ({systemd_service})"
        else:
            # Use docker compose directly
            stop_args = ['stop']
            if request.services:
                stop_args.extend(request.services)

            result = _run_compose_command(project_config, stop_args, timeout=60)
            output = result.stdout + result.stderr
            method = "docker compose"

        if result.returncode == 0:
            return ComposeOperationResponse(
                success=True,
                project=request.project,
                operation="stop",
                message=f"Services stopped via {method}",
                output=output,
                services=request.services,
                timestamp=datetime.now().isoformat()
            )
        else:
            return ComposeOperationResponse(
                success=False,
                project=request.project,
                operation="stop",
                message="Failed to stop services",
                output=output,
                services=request.services,
                timestamp=datetime.now().isoformat(),
                error=f"Command exited with code {result.returncode}"
            )

    except subprocess.TimeoutExpired:
        return ComposeOperationResponse(
            success=False,
            project=request.project,
            operation="stop",
            message="Command timed out",
            services=request.services,
            timestamp=datetime.now().isoformat(),
            error="Command timed out"
        )
    except Exception as e:
        logger.error(f"Error running compose stop: {e}")
        return ComposeOperationResponse(
            success=False,
            project=request.project,
            operation="stop",
            message="Error stopping services",
            services=request.services,
            timestamp=datetime.now().isoformat(),
            error=str(e)
        )


@app.post("/docker-compose/restart", response_model=ComposeOperationResponse)
async def compose_restart(request: ComposeOperationRequest):
    """
    Restart Docker Compose services with optional fresh pull.

    **Request Body:**
    - `project`: Project name (e.g., 'operator-ui', 'teleop')
    - `services`: (Optional) Specific services to restart
    - `pull`: (Optional) Pull latest images before restarting (default: false)

    When `pull: true`, this performs: pull -> down -> up -d
    If the project has a systemd_service configured, uses systemctl restart instead.
    """
    project_config = _get_compose_project(request.project)
    if not project_config:
        return ComposeOperationResponse(
            success=False,
            project=request.project,
            operation="restart",
            message="Unknown project",
            timestamp=datetime.now().isoformat(),
            error=f"Unknown project: {request.project}. Available: {list(COMPOSE_PROJECTS.keys())}"
        )

    # Check if this project uses systemd
    systemd_service = project_config.get('systemd_service')

    try:
        output_parts = []

        if request.pull:
            # Pull -> Down -> Up sequence for fresh images
            # Pull (always use docker compose)
            pull_args = ['pull']
            if request.services:
                pull_args.extend(request.services)

            pull_result = _run_compose_command(project_config, pull_args, timeout=300)
            output_parts.append(f"=== Pull ===\n{pull_result.stdout}{pull_result.stderr}")

            if pull_result.returncode != 0:
                return ComposeOperationResponse(
                    success=False,
                    project=request.project,
                    operation="restart",
                    message="Failed to pull images",
                    output='\n'.join(output_parts),
                    services=request.services,
                    timestamp=datetime.now().isoformat(),
                    error=f"docker compose pull exited with code {pull_result.returncode}"
                )

            # Down/Stop
            if systemd_service and not request.services:
                stop_result = _run_systemctl_command(systemd_service, 'stop', timeout=60)
                output_parts.append(f"=== systemctl stop {systemd_service} ===\n{stop_result.stdout}{stop_result.stderr}")
            else:
                down_result = _run_compose_command(project_config, ['down'], timeout=60)
                output_parts.append(f"=== Down ===\n{down_result.stdout}{down_result.stderr}")

            # Up/Start
            if systemd_service and not request.services:
                result = _run_systemctl_command(systemd_service, 'start', timeout=120)
                output_parts.append(f"=== systemctl start {systemd_service} ===\n{result.stdout}{result.stderr}")
                method = f"systemctl ({systemd_service})"
            else:
                up_args = ['up', '-d']
                if request.services:
                    up_args.extend(request.services)

                result = _run_compose_command(project_config, up_args, timeout=120)
                output_parts.append(f"=== Up ===\n{result.stdout}{result.stderr}")
                method = "docker compose"
        else:
            # Simple restart
            if systemd_service and not request.services:
                result = _run_systemctl_command(systemd_service, 'restart', timeout=120)
                output_parts.append(f"=== systemctl restart {systemd_service} ===\n{result.stdout}{result.stderr}")
                method = f"systemctl ({systemd_service})"
            else:
                restart_args = ['restart']
                if request.services:
                    restart_args.extend(request.services)

                result = _run_compose_command(project_config, restart_args, timeout=120)
                output_parts.append(result.stdout + result.stderr)
                method = "docker compose"

        output = '\n'.join(output_parts)

        if result.returncode == 0:
            return ComposeOperationResponse(
                success=True,
                project=request.project,
                operation="restart",
                message=f"Services restarted via {method}{' with fresh images' if request.pull else ''}",
                output=output,
                services=request.services,
                timestamp=datetime.now().isoformat()
            )
        else:
            return ComposeOperationResponse(
                success=False,
                project=request.project,
                operation="restart",
                message="Failed to restart services",
                output=output,
                services=request.services,
                timestamp=datetime.now().isoformat(),
                error=f"Command exited with code {result.returncode}"
            )

    except subprocess.TimeoutExpired:
        return ComposeOperationResponse(
            success=False,
            project=request.project,
            operation="restart",
            message="Command timed out",
            services=request.services,
            timestamp=datetime.now().isoformat(),
            error="Command timed out"
        )
    except Exception as e:
        logger.error(f"Error running compose restart: {e}")
        return ComposeOperationResponse(
            success=False,
            project=request.project,
            operation="restart",
            message="Error restarting services",
            services=request.services,
            timestamp=datetime.now().isoformat(),
            error=str(e)
        )


@app.post("/docker-compose/pull", response_model=ComposeOperationResponse)
async def compose_pull(request: ComposeOperationRequest):
    """
    Pull latest images for Docker Compose services.

    **Request Body:**
    - `project`: Project name (e.g., 'operator-ui', 'teleop')
    - `services`: (Optional) Specific services to pull images for
    """
    project_config = _get_compose_project(request.project)
    if not project_config:
        return ComposeOperationResponse(
            success=False,
            project=request.project,
            operation="pull",
            message="Unknown project",
            timestamp=datetime.now().isoformat(),
            error=f"Unknown project: {request.project}. Available: {list(COMPOSE_PROJECTS.keys())}"
        )

    try:
        pull_args = ['pull']
        if request.services:
            pull_args.extend(request.services)

        result = _run_compose_command(project_config, pull_args, timeout=300)
        output = result.stdout + result.stderr

        if result.returncode == 0:
            return ComposeOperationResponse(
                success=True,
                project=request.project,
                operation="pull",
                message="Images pulled successfully",
                output=output,
                services=request.services,
                timestamp=datetime.now().isoformat()
            )
        else:
            return ComposeOperationResponse(
                success=False,
                project=request.project,
                operation="pull",
                message="Failed to pull images",
                output=output,
                services=request.services,
                timestamp=datetime.now().isoformat(),
                error=f"docker compose pull exited with code {result.returncode}"
            )

    except subprocess.TimeoutExpired:
        return ComposeOperationResponse(
            success=False,
            project=request.project,
            operation="pull",
            message="Command timed out",
            services=request.services,
            timestamp=datetime.now().isoformat(),
            error="docker compose pull timed out after 300 seconds"
        )
    except Exception as e:
        logger.error(f"Error running compose pull: {e}")
        return ComposeOperationResponse(
            success=False,
            project=request.project,
            operation="pull",
            message="Error pulling images",
            services=request.services,
            timestamp=datetime.now().isoformat(),
            error=str(e)
        )


@app.get("/docker-compose/logs", response_model=ComposeLogsResponse)
async def compose_logs(project: str, services: str = None, tail: int = 100):
    """
    Get recent logs from Docker Compose services.

    **Query Parameters:**
    - `project`: Project name (e.g., 'operator-ui', 'teleop')
    - `services`: (Optional) Comma-separated list of services to get logs from
    - `tail`: (Optional) Number of lines to return (default: 100, max: 10000)
    """
    project_config = _get_compose_project(project)
    if not project_config:
        return ComposeLogsResponse(
            success=False,
            project=project,
            logs=[],
            lines=0,
            timestamp=datetime.now().isoformat(),
            error=f"Unknown project: {project}. Available: {list(COMPOSE_PROJECTS.keys())}"
        )

    # Clamp tail value
    tail = max(1, min(tail, 10000))

    # Parse services if provided
    service_list = [s.strip() for s in services.split(',')] if services else None

    try:
        # Build docker compose logs command
        logs_args = ['logs', '--no-color', '--tail', str(tail)]
        if service_list:
            logs_args.extend(service_list)

        result = _run_compose_command(project_config, logs_args, timeout=30)

        # Split output into lines
        log_lines = result.stdout.split('\n') if result.stdout else []
        # Remove empty trailing line
        if log_lines and not log_lines[-1]:
            log_lines = log_lines[:-1]

        if result.returncode == 0:
            return ComposeLogsResponse(
                success=True,
                project=project,
                logs=log_lines,
                lines=len(log_lines),
                services=service_list,
                timestamp=datetime.now().isoformat()
            )
        else:
            return ComposeLogsResponse(
                success=False,
                project=project,
                logs=log_lines,
                lines=len(log_lines),
                services=service_list,
                timestamp=datetime.now().isoformat(),
                error=f"docker compose logs exited with code {result.returncode}: {result.stderr}"
            )

    except subprocess.TimeoutExpired:
        return ComposeLogsResponse(
            success=False,
            project=project,
            logs=[],
            lines=0,
            services=service_list,
            timestamp=datetime.now().isoformat(),
            error="docker compose logs timed out"
        )
    except Exception as e:
        logger.error(f"Error getting compose logs: {e}")
        return ComposeLogsResponse(
            success=False,
            project=project,
            logs=[],
            lines=0,
            services=service_list,
            timestamp=datetime.now().isoformat(),
            error=str(e)
        )


@app.get("/docker-compose/logs/stream")
async def stream_compose_logs(project: str, services: str = None):
    """
    Stream logs from Docker Compose services in real-time using Server-Sent Events (SSE).

    **Query Parameters:**
    - `project`: Project name (e.g., 'operator-ui', 'teleop')
    - `services`: (Optional) Comma-separated list of services to stream logs from

    **Returns:**
    - SSE stream with log lines as `data: <log_line>` events
    - Connect with EventSource or curl: `curl -N http://localhost:5000/docker-compose/logs/stream?project=operator-ui`
    """
    project_config = _get_compose_project(project)
    if not project_config:
        return StreamingResponse(
            iter([f"data: Error: Unknown project: {project}. Available: {list(COMPOSE_PROJECTS.keys())}\n\n"]),
            media_type="text/event-stream"
        )

    # Parse services if provided
    service_list = [s.strip() for s in services.split(',')] if services else []

    docker_cmd = get_nixos_command('docker')
    compose_file = project_config['file']
    compose_path = project_config['path']

    def generate():
        # Build command: docker compose -f <file> logs -f [services...]
        cmd = ['stdbuf', '-oL', docker_cmd, 'compose', '-f', compose_file, 'logs', '-f', '--no-color']
        if service_list:
            cmd.extend(service_list)

        try:
            process = subprocess.Popen(
                cmd,
                cwd=compose_path,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                bufsize=0
            )

            while True:
                line = process.stdout.readline()
                if not line:
                    # Check if process has ended
                    if process.poll() is not None:
                        break
                    continue

                decoded_line = line.decode('utf-8', errors='replace').rstrip()
                yield f"data: {decoded_line}\n\n"

        except Exception as e:
            yield f"data: Error streaming logs: {str(e)}\n\n"
        finally:
            if 'process' in locals() and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no"
        }
    )


# =====================================================
# Positronic Phantom Container Endpoints
# =====================================================

@app.get("/positronic/status", response_model=PositronicStatusResponse)
async def positronic_status():
    """
    Get comprehensive status of the positronic_phantom container.

    Returns detailed information similar to docker compose status including:
    - Container state and status
    - Image information
    - Port mappings
    - CPU affinity (runtime from /proc)
    - Memory usage
    - Network configuration
    - Volume mounts
    - Key environment variables
    """
    docker_cmd = get_nixos_command('docker')
    container_name = PHANTOM_CONTAINER_NAME

    try:
        # Check if container exists
        check_result = subprocess.run(
            [docker_cmd, 'ps', '-a', '--filter', f'name=^{container_name}$', '--format', '{{.Names}}'],
            capture_output=True,
            text=True,
            timeout=10
        )

        if container_name not in check_result.stdout:
            return PositronicStatusResponse(
                success=True,
                name=container_name,
                state="not_found",
                status="Container does not exist",
                timestamp=datetime.now().isoformat()
            )

        # Get detailed container info via docker inspect
        inspect_result = subprocess.run(
            [docker_cmd, 'inspect', container_name],
            capture_output=True,
            text=True,
            timeout=10
        )

        if inspect_result.returncode != 0:
            return PositronicStatusResponse(
                success=False,
                name=container_name,
                state="unknown",
                status="Failed to inspect container",
                timestamp=datetime.now().isoformat(),
                error=inspect_result.stderr
            )

        inspect_data = json.loads(inspect_result.stdout)[0]

        # Extract basic info
        state = inspect_data.get('State', {})
        config = inspect_data.get('Config', {})
        host_config = inspect_data.get('HostConfig', {})
        network_settings = inspect_data.get('NetworkSettings', {})

        container_state = state.get('Status', 'unknown')
        is_running = state.get('Running', False)

        # Build human-readable status
        if is_running:
            started_at = state.get('StartedAt', '')
            if started_at:
                try:
                    start_time = datetime.fromisoformat(started_at.replace('Z', '+00:00'))
                    uptime = datetime.now(start_time.tzinfo) - start_time
                    hours, remainder = divmod(int(uptime.total_seconds()), 3600)
                    minutes, seconds = divmod(remainder, 60)
                    if hours > 24:
                        days = hours // 24
                        hours = hours % 24
                        status_str = f"Up {days} days, {hours} hours"
                    elif hours > 0:
                        status_str = f"Up {hours} hours, {minutes} minutes"
                    else:
                        status_str = f"Up {minutes} minutes"
                except:
                    status_str = "Up"
            else:
                status_str = "Up"
        else:
            status_str = f"Exited ({state.get('ExitCode', 0)})"

        # Get image info
        image = config.get('Image', '')

        # Parse port mappings
        ports_list = []
        port_bindings = host_config.get('PortBindings', {}) or {}
        for container_port, bindings in port_bindings.items():
            if bindings:
                for binding in bindings:
                    host_port = binding.get('HostPort', '')
                    if host_port:
                        # Format: host_port:container_port
                        container_port_num = container_port.split('/')[0]
                        ports_list.append(f"{host_port}:{container_port_num}")
        ports_str = ', '.join(ports_list) if ports_list else ""

        # Get runtime CPU affinity from /proc if container is running
        cpuset = ""
        if is_running:
            pid = state.get('Pid', 0)
            if pid and pid != 0:
                try:
                    with open(f'/proc/{pid}/status', 'r') as f:
                        for line in f:
                            if line.startswith('Cpus_allowed_list:'):
                                cpuset = line.split(':', 1)[1].strip()
                                break
                except (FileNotFoundError, PermissionError):
                    cpuset = ""

        # Get memory stats if running
        memory_usage = None
        memory_limit = None
        cpu_percent = None
        if is_running:
            try:
                stats_result = subprocess.run(
                    [docker_cmd, 'stats', '--no-stream', '--format',
                     '{{.MemUsage}}|{{.CPUPerc}}', container_name],
                    capture_output=True,
                    text=True,
                    timeout=10
                )
                if stats_result.returncode == 0 and stats_result.stdout.strip():
                    parts = stats_result.stdout.strip().split('|')
                    if len(parts) >= 2:
                        mem_parts = parts[0].split(' / ')
                        if len(mem_parts) >= 2:
                            memory_usage = mem_parts[0].strip()
                            memory_limit = mem_parts[1].strip()
                        cpu_percent = parts[1].strip()
            except:
                pass

        # Parse networks
        networks = []
        networks_data = network_settings.get('Networks', {}) or {}
        for net_name, net_info in networks_data.items():
            networks.append(PositronicNetwork(
                name=net_name,
                ip_address=net_info.get('IPAddress'),
                gateway=net_info.get('Gateway')
            ))

        # Parse mounts
        mounts = []
        mounts_data = inspect_data.get('Mounts', []) or []
        for mount in mounts_data:
            mounts.append(PositronicMount(
                source=mount.get('Source', ''),
                destination=mount.get('Destination', ''),
                mode=mount.get('Mode', 'rw') or 'rw'
            ))

        # Extract key environment variables (filter sensitive ones)
        env_vars = {}
        env_list = config.get('Env', []) or []
        key_env_prefixes = ['ROS_', 'DISPLAY', 'NVIDIA', 'CUDA', 'PHANTOM', 'ROBOT']
        for env in env_list:
            if '=' in env:
                key, value = env.split('=', 1)
                for prefix in key_env_prefixes:
                    if key.startswith(prefix):
                        env_vars[key] = value
                        break

        return PositronicStatusResponse(
            success=True,
            name=container_name,
            state=container_state,
            status=status_str,
            image=image,
            created=inspect_data.get('Created'),
            started_at=state.get('StartedAt'),
            ports=ports_str,
            cpuset=cpuset,
            memory_usage=memory_usage,
            memory_limit=memory_limit,
            cpu_percent=cpu_percent,
            networks=networks,
            mounts=mounts,
            env=env_vars,
            timestamp=datetime.now().isoformat()
        )

    except subprocess.TimeoutExpired:
        return PositronicStatusResponse(
            success=False,
            name=container_name,
            state="unknown",
            status="Command timed out",
            timestamp=datetime.now().isoformat(),
            error="docker inspect timed out"
        )
    except Exception as e:
        logger.error(f"Error getting positronic status: {e}")
        return PositronicStatusResponse(
            success=False,
            name=container_name,
            state="unknown",
            status="Error",
            timestamp=datetime.now().isoformat(),
            error=str(e)
        )


@app.post("/positronic/build", response_model=PositronicBuildResponse)
async def positronic_build(request: PositronicBuildRequest = None):
    """
    Build the phantom Docker image.

    **Request Body (optional):**
    - `target`: Build target (default: "phantom", options: phantom, phantom-cpu, phantom-production)
    """
    target = request.target if request else "phantom"
    valid_targets = ["phantom", "phantom-cpu", "phantom-production", "phantom-felix"]

    if target not in valid_targets:
        return PositronicBuildResponse(
            success=False,
            target=target,
            message=f"Invalid target: {target}",
            timestamp=datetime.now().isoformat(),
            error=f"Valid targets: {valid_targets}"
        )

    build_script = os.path.join(POSITRONIC_CONTROL_PATH, "bin", "build.sh")

    if not os.path.exists(build_script):
        return PositronicBuildResponse(
            success=False,
            target=target,
            message="Build script not found",
            timestamp=datetime.now().isoformat(),
            error=f"Build script not found at {build_script}"
        )

    try:
        # Run build script - this can take a long time
        result = subprocess.run(
            [build_script, target],
            capture_output=True,
            text=True,
            timeout=1800,  # 30 minute timeout for builds
            cwd=POSITRONIC_CONTROL_PATH
        )

        # Get last 100 lines of output
        output_lines = result.stdout.split('\n')[-100:]
        output = '\n'.join(output_lines)

        if result.returncode == 0:
            return PositronicBuildResponse(
                success=True,
                target=target,
                message=f"Successfully built {target}",
                output=output,
                timestamp=datetime.now().isoformat()
            )
        else:
            return PositronicBuildResponse(
                success=False,
                target=target,
                message=f"Build failed with exit code {result.returncode}",
                output=output,
                timestamp=datetime.now().isoformat(),
                error=result.stderr[-500:] if result.stderr else None
            )

    except subprocess.TimeoutExpired:
        return PositronicBuildResponse(
            success=False,
            target=target,
            message="Build timed out",
            timestamp=datetime.now().isoformat(),
            error="Build exceeded 30 minute timeout"
        )
    except Exception as e:
        logger.error(f"Error building positronic: {e}")
        return PositronicBuildResponse(
            success=False,
            target=target,
            message="Build failed",
            timestamp=datetime.now().isoformat(),
            error=str(e)
        )


@app.post("/positronic/up", response_model=PositronicUpResponse)
async def positronic_up(request: PositronicUpRequest = None):
    """
    Start the positronic_phantom container in development mode.

    **Request Body (optional):**
    - `command`: Command to run in container (default: "sleep infinity")
    - `dev`: Use development mode (default: true)
    """
    command = request.command if request else "sleep infinity"
    dev = request.dev if request else True

    phantom_script = os.path.join(POSITRONIC_CONTROL_PATH, "bin", "phantom")

    if not os.path.exists(phantom_script):
        return PositronicUpResponse(
            success=False,
            message="Phantom script not found",
            timestamp=datetime.now().isoformat(),
            error=f"Phantom script not found at {phantom_script}"
        )

    try:
        # Build command
        cmd_args = [phantom_script, 'up']
        if dev:
            cmd_args.append('--dev')
        cmd_args.append(command)

        # Set TMPDIR environment
        env = os.environ.copy()
        env['TMPDIR'] = '/tmp'

        result = subprocess.run(
            cmd_args,
            capture_output=True,
            text=True,
            timeout=120,  # 2 minute timeout
            cwd=POSITRONIC_CONTROL_PATH,
            env=env
        )

        if result.returncode == 0:
            return PositronicUpResponse(
                success=True,
                message=f"Container started successfully",
                output=result.stdout,
                timestamp=datetime.now().isoformat()
            )
        else:
            return PositronicUpResponse(
                success=False,
                message=f"Failed to start container (exit code {result.returncode})",
                output=result.stdout,
                timestamp=datetime.now().isoformat(),
                error=result.stderr
            )

    except subprocess.TimeoutExpired:
        return PositronicUpResponse(
            success=False,
            message="Command timed out",
            timestamp=datetime.now().isoformat(),
            error="phantom up timed out after 2 minutes"
        )
    except Exception as e:
        logger.error(f"Error starting positronic: {e}")
        return PositronicUpResponse(
            success=False,
            message="Failed to start container",
            timestamp=datetime.now().isoformat(),
            error=str(e)
        )


@app.post("/positronic/compose/up", response_model=PositronicUpResponse)
async def positronic_compose_up(request: PositronicComposeUpRequest = None):
    """
    Start the positronic_phantom container using docker compose up.

    Uses the development docker-compose.yaml file directly.
    After starting, automatically sets cpuset to limit CPU cores.
    This is the counterpart to /policy/stop which uses docker compose down.

    **Request Body (optional):**
    - `ros_domain_id`: ROS2 domain ID for network isolation (default: 101, range: 0-232)
    """
    ros_domain_id = request.ros_domain_id if request else 101

    docker_cmd = get_nixos_command('docker')
    compose_file = os.path.join(POSITRONIC_CONTROL_PATH, 'docker', 'development.docker-compose.yaml')

    if not os.path.exists(compose_file):
        return PositronicUpResponse(
            success=False,
            message="Compose file not found",
            timestamp=datetime.now().isoformat(),
            error=f"Compose file not found at {compose_file}"
        )

    try:
        # Get compose env and set ROS_DOMAIN_ID
        env = _get_compose_env()
        env['ROS_DOMAIN_ID'] = str(ros_domain_id)
        # Override default command with sleep infinity to keep container alive
        # Policy will be launched separately via /policy/run
        env['PHANTOM_CMD'] = 'sleep infinity'

        result = subprocess.run(
            [docker_cmd, 'compose', '-f', compose_file, 'up', '-d'],
            cwd=POSITRONIC_CONTROL_PATH,
            capture_output=True,
            text=True,
            timeout=120,  # 2 minute timeout
            env=env
        )

        if result.returncode == 0:
            # Set cpuset after container starts (no sudo - user should be in docker group)
            cpuset_result = subprocess.run(
                [docker_cmd, 'update', f'--cpuset-cpus={PHANTOM_DEFAULT_CPUSET}', PHANTOM_CONTAINER_NAME],
                capture_output=True,
                text=True,
                timeout=30
            )

            # Verify cpuset was applied by inspecting the container
            cpuset_msg = ""
            if cpuset_result.returncode == 0:
                inspect_result = subprocess.run(
                    [docker_cmd, 'inspect', '--format={{.HostConfig.CpusetCpus}}', PHANTOM_CONTAINER_NAME],
                    capture_output=True,
                    text=True,
                    timeout=10
                )
                actual_cpuset = inspect_result.stdout.strip() if inspect_result.returncode == 0 else PHANTOM_DEFAULT_CPUSET
                cpuset_msg = f" (cpuset: {actual_cpuset})"
            else:
                cpuset_msg = f" (warning: cpuset failed: {cpuset_result.stderr})"

            return PositronicUpResponse(
                success=True,
                message=f"Container started via docker compose up (ROS_DOMAIN_ID: {ros_domain_id}){cpuset_msg}",
                output=result.stdout + result.stderr,
                timestamp=datetime.now().isoformat()
            )
        else:
            return PositronicUpResponse(
                success=False,
                message=f"docker compose up failed (exit code {result.returncode})",
                output=result.stdout,
                timestamp=datetime.now().isoformat(),
                error=result.stderr
            )

    except subprocess.TimeoutExpired:
        return PositronicUpResponse(
            success=False,
            message="Command timed out",
            timestamp=datetime.now().isoformat(),
            error="docker compose up timed out after 2 minutes"
        )
    except Exception as e:
        logger.error(f"Error starting positronic via compose: {e}")
        return PositronicUpResponse(
            success=False,
            message="Failed to start container",
            timestamp=datetime.now().isoformat(),
            error=str(e)
        )


@app.post("/positronic/compose/restart", response_model=PositronicUpResponse)
async def positronic_compose_restart():
    """
    Restart the positronic_phantom container using docker compose restart.

    Uses the development docker-compose.yaml file directly.
    """
    docker_cmd = get_nixos_command('docker')
    compose_file = os.path.join(POSITRONIC_CONTROL_PATH, 'docker', 'development.docker-compose.yaml')

    if not os.path.exists(compose_file):
        return PositronicUpResponse(
            success=False,
            message="Compose file not found",
            timestamp=datetime.now().isoformat(),
            error=f"Compose file not found at {compose_file}"
        )

    try:
        result = subprocess.run(
            [docker_cmd, 'compose', '-f', compose_file, 'restart'],
            cwd=POSITRONIC_CONTROL_PATH,
            capture_output=True,
            text=True,
            timeout=120,  # 2 minute timeout
            env=_get_compose_env()
        )

        if result.returncode == 0:
            return PositronicUpResponse(
                success=True,
                message="Container restarted via docker compose restart",
                output=result.stdout + result.stderr,
                timestamp=datetime.now().isoformat()
            )
        else:
            return PositronicUpResponse(
                success=False,
                message=f"docker compose restart failed (exit code {result.returncode})",
                output=result.stdout,
                timestamp=datetime.now().isoformat(),
                error=result.stderr
            )

    except subprocess.TimeoutExpired:
        return PositronicUpResponse(
            success=False,
            message="Command timed out",
            timestamp=datetime.now().isoformat(),
            error="docker compose restart timed out after 2 minutes"
        )
    except Exception as e:
        logger.error(f"Error restarting positronic via compose: {e}")
        return PositronicUpResponse(
            success=False,
            message="Failed to restart container",
            timestamp=datetime.now().isoformat(),
            error=str(e)
        )


@app.post("/positronic/compose/down", response_model=PositronicStopResponse)
async def positronic_compose_down():
    """
    Stop the positronic_phantom container using docker compose down.

    Uses the development docker-compose.yaml file directly.
    """
    docker_cmd = get_nixos_command('docker')
    compose_file = os.path.join(POSITRONIC_CONTROL_PATH, 'docker', 'development.docker-compose.yaml')

    if not os.path.exists(compose_file):
        return PositronicStopResponse(
            success=False,
            message="Compose file not found",
            timestamp=datetime.now().isoformat(),
            error=f"Compose file not found at {compose_file}"
        )

    try:
        result = subprocess.run(
            [docker_cmd, 'compose', '-f', compose_file, 'down', '-t', '60'],
            cwd=POSITRONIC_CONTROL_PATH,
            capture_output=True,
            text=True,
            timeout=120,  # 2 minute timeout
            env=_get_compose_env()
        )

        if result.returncode == 0:
            return PositronicStopResponse(
                success=True,
                message="Container stopped via docker compose down",
                output=result.stdout + result.stderr,
                timestamp=datetime.now().isoformat()
            )
        else:
            return PositronicStopResponse(
                success=False,
                message=f"docker compose down failed (exit code {result.returncode})",
                output=result.stdout,
                timestamp=datetime.now().isoformat(),
                error=result.stderr
            )

    except subprocess.TimeoutExpired:
        return PositronicStopResponse(
            success=False,
            message="Command timed out",
            timestamp=datetime.now().isoformat(),
            error="docker compose down timed out after 2 minutes"
        )
    except Exception as e:
        logger.error(f"Error stopping positronic via compose: {e}")
        return PositronicStopResponse(
            success=False,
            message="Failed to stop container",
            timestamp=datetime.now().isoformat(),
            error=str(e)
        )


@app.post("/positronic/compose/stop", response_model=PositronicStopResponse)
async def positronic_compose_stop():
    """
    Stop the positronic_phantom container using docker compose stop.

    Unlike /positronic/compose/down, this keeps the container (in exited state)
    so it can be restarted quickly with docker compose start.
    """
    docker_cmd = get_nixos_command('docker')
    compose_file = os.path.join(POSITRONIC_CONTROL_PATH, 'docker', 'development.docker-compose.yaml')

    if not os.path.exists(compose_file):
        return PositronicStopResponse(
            success=False,
            message="Compose file not found",
            timestamp=datetime.now().isoformat(),
            error=f"Compose file not found at {compose_file}"
        )

    try:
        result = subprocess.run(
            [docker_cmd, 'compose', '-f', compose_file, 'stop'],
            cwd=POSITRONIC_CONTROL_PATH,
            capture_output=True,
            text=True,
            timeout=120,  # 2 minute timeout
            env=_get_compose_env()
        )

        if result.returncode == 0:
            return PositronicStopResponse(
                success=True,
                message="Container stopped via docker compose stop (container preserved)",
                output=result.stdout + result.stderr,
                timestamp=datetime.now().isoformat()
            )
        else:
            return PositronicStopResponse(
                success=False,
                message=f"docker compose stop failed (exit code {result.returncode})",
                output=result.stdout,
                timestamp=datetime.now().isoformat(),
                error=result.stderr
            )

    except subprocess.TimeoutExpired:
        return PositronicStopResponse(
            success=False,
            message="Command timed out",
            timestamp=datetime.now().isoformat(),
            error="docker compose stop timed out after 2 minutes"
        )
    except Exception as e:
        logger.error(f"Error stopping positronic via compose stop: {e}")
        return PositronicStopResponse(
            success=False,
            message="Failed to stop container",
            timestamp=datetime.now().isoformat(),
            error=str(e)
        )


@app.post("/positronic/cpuset", response_model=PositronicCpusetResponse)
async def positronic_cpuset(request: PositronicCpusetRequest = None):
    """
    Set CPU affinity for the positronic_phantom container.

    **Request Body (optional):**
    - `cpus`: CPU cores to assign (default: "0-14", format: "0-14" or "0,2,4,6")
    """
    cpus = request.cpus if request else PHANTOM_DEFAULT_CPUSET
    docker_cmd = get_nixos_command('docker')
    container_name = PHANTOM_CONTAINER_NAME

    try:
        # Check if container exists and is running
        check_result = subprocess.run(
            [docker_cmd, 'ps', '--filter', f'name=^{container_name}$', '--format', '{{.Names}}'],
            capture_output=True,
            text=True,
            timeout=10
        )

        if container_name not in check_result.stdout:
            return PositronicCpusetResponse(
                success=False,
                cpus=cpus,
                message="Container is not running",
                timestamp=datetime.now().isoformat(),
                error=f"Container {container_name} is not running or does not exist"
            )

        # Update cpuset using docker update
        result = subprocess.run(
            [docker_cmd, 'update', f'--cpuset-cpus={cpus}', container_name],
            capture_output=True,
            text=True,
            timeout=30
        )

        if result.returncode == 0:
            return PositronicCpusetResponse(
                success=True,
                cpus=cpus,
                message=f"CPU affinity set to {cpus}",
                output=result.stdout,
                timestamp=datetime.now().isoformat()
            )
        else:
            return PositronicCpusetResponse(
                success=False,
                cpus=cpus,
                message="Failed to set CPU affinity",
                output=result.stdout,
                timestamp=datetime.now().isoformat(),
                error=result.stderr
            )

    except subprocess.TimeoutExpired:
        return PositronicCpusetResponse(
            success=False,
            cpus=cpus,
            message="Command timed out",
            timestamp=datetime.now().isoformat(),
            error="docker update timed out"
        )
    except Exception as e:
        logger.error(f"Error setting positronic cpuset: {e}")
        return PositronicCpusetResponse(
            success=False,
            cpus=cpus,
            message="Failed to set CPU affinity",
            timestamp=datetime.now().isoformat(),
            error=str(e)
        )


@app.post("/positronic/stop", response_model=PositronicStopResponse)
async def positronic_stop():
    """
    Stop the positronic_phantom container.
    """
    docker_cmd = get_nixos_command('docker')
    container_name = PHANTOM_CONTAINER_NAME

    try:
        # Check if container exists
        check_result = subprocess.run(
            [docker_cmd, 'ps', '-a', '--filter', f'name=^{container_name}$', '--format', '{{.Names}}'],
            capture_output=True,
            text=True,
            timeout=10
        )

        if container_name not in check_result.stdout:
            return PositronicStopResponse(
                success=True,
                message="Container does not exist",
                timestamp=datetime.now().isoformat()
            )

        # Stop container
        result = subprocess.run(
            [docker_cmd, 'stop', container_name],
            capture_output=True,
            text=True,
            timeout=60  # 1 minute timeout for stop
        )

        if result.returncode == 0:
            return PositronicStopResponse(
                success=True,
                message=f"Container {container_name} stopped successfully",
                output=result.stdout,
                timestamp=datetime.now().isoformat()
            )
        else:
            return PositronicStopResponse(
                success=False,
                message=f"Failed to stop container (exit code {result.returncode})",
                output=result.stdout,
                timestamp=datetime.now().isoformat(),
                error=result.stderr
            )

    except subprocess.TimeoutExpired:
        return PositronicStopResponse(
            success=False,
            message="Command timed out",
            timestamp=datetime.now().isoformat(),
            error="docker stop timed out after 1 minute"
        )
    except Exception as e:
        logger.error(f"Error stopping positronic: {e}")
        return PositronicStopResponse(
            success=False,
            message="Failed to stop container",
            timestamp=datetime.now().isoformat(),
            error=str(e)
        )


def main():
    """Main entry point for the application."""
    # For PyInstaller compatibility
    import sys
    import os

    # Add current directory to Python path for PyInstaller
    if getattr(sys, 'frozen', False):
        # Running as PyInstaller executable
        application_path = os.path.dirname(sys.executable)
        sys.path.insert(0, application_path)

        # Set environment variables for better compatibility
        os.environ['PYTHONPATH'] = application_path
        os.environ['PYTHONIOENCODING'] = 'utf-8'

        # Try to find and set Python library path
        try:
            import sysconfig
            lib_dir = sysconfig.get_config_var('LIBDIR')
            if lib_dir and os.path.exists(lib_dir):
                current_ld_path = os.environ.get('LD_LIBRARY_PATH', '')
                if lib_dir not in current_ld_path:
                    os.environ['LD_LIBRARY_PATH'] = lib_dir + ':' + current_ld_path
        except:
            pass

    try:
        uvicorn.run(
            app,  # Use the app object directly instead of string reference
            host=API_HOST,
            port=API_PORT,
            log_level=LOG_LEVEL.lower()
        )
    except Exception as e:
        print(f"Error starting application: {e}")
        print(f"Python executable: {sys.executable}")
        print(f"Python path: {sys.path}")
        print(f"Current working directory: {os.getcwd()}")
        print(f"Environment variables:")
        for key, value in os.environ.items():
            if 'PYTHON' in key or 'LD_LIBRARY' in key:
                print(f"  {key}={value}")
        sys.exit(1)


if __name__ == "__main__":
    main()
