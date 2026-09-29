#!/bin/bash

# Multi-Source CCTV System Launcher Script
# Enhanced with proper error handling, aggressive cleanup, and auto GUI window

set -e  # Exit on error
set -u  # Exit on undefined variable

# ============================================
# Cleanup Function
# ============================================
cleanup() {
    local exit_code=$?
    echo ""
    echo "============================================"
    if [ $exit_code -eq 0 ]; then
        echo "[OK] CCTV System Stopped Gracefully"
    elif [ $exit_code -eq 130 ]; then
        echo "[OK] CCTV System Stopped by User (Ctrl+C)"
    else
        echo "[WARN]  CCTV System Stopped (Exit Code: $exit_code)"
    fi
    echo "============================================"

    echo "[INFO] Stopping GUI window..."
    pkill -9 -f "anpr_webview_gui" 2>/dev/null || true

    # Force kill Python app process if still running
    echo "[INFO] Stopping Flask application..."
    pkill -9 -f "python.*app.py" 2>/dev/null || true

    # Force kill any OpenCV/YOLO processes
    echo "[INFO] Stopping camera feeds and AI detection..."
    pkill -9 -f "cv2" 2>/dev/null || true
    pkill -9 -f "ultralytics" 2>/dev/null || true
    pkill -9 -f "yolo" 2>/dev/null || true

    # Kill any Python processes from this venv
    if [ -n "${VIRTUAL_ENV:-}" ]; then
        VENV_PYTHON="${VIRTUAL_ENV}/bin/python"
        pkill -9 -f "$VENV_PYTHON" 2>/dev/null || true
    fi

    # Kill all child processes of this script
    echo "[INFO] Cleaning up child processes..."
    if [ -n "${SCRIPT_PID:-}" ]; then
        pkill -9 -P $SCRIPT_PID 2>/dev/null || true
    fi

    # Kill background jobs from this shell
    jobs -p | xargs -r kill -9 2>/dev/null || true

    # Deactivate virtual environment if active
    if [ -n "${VIRTUAL_ENV:-}" ]; then
        echo "[INFO] Deactivating virtual environment..."
        deactivate 2>/dev/null || true
    fi

    # Final cleanup - kill any lingering Flask processes on port 4000
    echo "[INFO] Releasing port 4000..."
    lsof -ti:4000 | xargs -r kill -9 2>/dev/null || true

    sleep 0.5

    echo "[OK] All processes cleaned up successfully"
    echo "============================================"

    exit $exit_code
}

# ============================================
# Error Handler
# ============================================
error_exit() {
    echo "[ERROR] ERROR: $1" >&2
    exit "${2:-1}"
}

# ============================================
# Signal Handlers
# ============================================
trap cleanup EXIT
trap 'echo ""; echo "[STOP] Received interrupt signal, cleaning up..."; exit 130' INT
trap 'echo ""; echo "[STOP] Received termination signal, cleaning up..."; exit 143' TERM
trap 'echo ""; echo "[STOP] Received quit signal, cleaning up..."; exit 131' QUIT

# ============================================
# Banner
# ============================================
echo "============================================"
echo "    [CAM] Multi-Source CCTV System Launcher"
echo "============================================"
echo ""

# ============================================
# Setup Working Directory
# ============================================
SCRIPT_PID=$$
SCRIPT_DIR="${HOME}/cctv_system"

if [ ! -d "$SCRIPT_DIR" ]; then
    error_exit "CCTV system directory not found: $SCRIPT_DIR" 1
fi

cd "$SCRIPT_DIR" || error_exit "Cannot change to directory: $SCRIPT_DIR"

echo "[DIR] Working directory: $SCRIPT_DIR"
echo ""

# ============================================
# Check Virtual Environment
# ============================================
if [ ! -d "venv" ]; then
    echo "[ERROR] Virtual environment not found!"
    echo ""
    echo "Please run setup first:"
    echo "  python3 -m venv venv"
    echo "  source venv/bin/activate"
    echo "  pip install -r requirements.txt"
    echo ""
    error_exit "Virtual environment missing" 1
fi

# ============================================
# Check Core Files
# ============================================
if [ ! -f "app.py" ]; then
    error_exit "app.py not found in $SCRIPT_DIR!" 1
fi

if [ ! -f "index.html" ]; then
    error_exit "index.html not found in $SCRIPT_DIR!" 1
fi

# ============================================
# Activate Virtual Environment
# ============================================
echo "[INFO] Activating virtual environment..."

if [ -f "venv/bin/activate" ]; then
    set +e
    source venv/bin/activate
    activate_result=$?
    set -e

    if [ $activate_result -ne 0 ]; then
        error_exit "Failed to activate virtual environment" 1
    fi
else
    error_exit "Virtual environment activation script not found" 1
fi

echo "[OK] Virtual environment activated: $VIRTUAL_ENV"
echo ""

# ============================================
# Show Python Info
# ============================================
echo "[PY] Python: $(which python 2>/dev/null || echo 'not found')"
echo "[PKG] Pip: $(which pip 2>/dev/null || echo 'not found')"
echo ""

# ============================================
# Check Dependencies
# ============================================
echo "[SEARCH] Checking dependencies..."

set +e
python << 'CHECKEOF'
import sys
import signal

def signal_handler(sig, frame):
    sys.exit(130)

signal.signal(signal.SIGINT, signal_handler)

critical_modules = ['flask', 'cv2', 'numpy']
missing = []

try:
    for module in critical_modules:
        try:
            __import__(module)
        except ImportError:
            missing.append(module)

    if missing:
        print(f"[ERROR] Missing critical modules: {', '.join(missing)}")
        print("\n? Install with:")
        print("  pip install flask opencv-python numpy")
        sys.exit(1)
    else:
        print("[OK] Critical dependencies OK")
        sys.exit(0)
except KeyboardInterrupt:
    sys.exit(130)
CHECKEOF

dep_check_result=$?
set -e

if [ $dep_check_result -eq 130 ]; then
    echo ""
    echo "[STOP] Dependency check interrupted"
    exit 130
fi

if [ $dep_check_result -ne 0 ]; then
    echo ""
    error_exit "Missing dependencies! Please install them first." 1
fi

# ============================================
# Optional Dependencies Check
# ============================================
echo ""
echo "[TEST] Checking optional dependencies..."

set +e
python -c "import importlib.util; exit(0 if importlib.util.find_spec('ultralytics') else 1)" 2>/dev/null
ultralytics_result=$?
set -e

if [ $ultralytics_result -eq 0 ]; then
    echo "[OK] ultralytics (YOLO) available"
    echo "[AI] AI Detection will be enabled"
else
    echo "[WARN]  ultralytics not installed"
    echo "[TIP] Install with: pip install ultralytics"
    echo "[INFO] Motion detection will be used as fallback"
fi

# ============================================
# Model Detection
# ============================================
echo ""
echo "[PKG] Scanning for YOLO models..."

model_count=0
for dir in "." "models" "weights" "yolo"; do
    if [ -d "$dir" ]; then
        pt_files=$(find "$dir" -maxdepth 1 -name "*.pt" -type f 2>/dev/null | wc -l)
        if [ "$pt_files" -gt 0 ]; then
            model_count=$((model_count + pt_files))
        fi
    fi
done

if [ "$model_count" -gt 0 ]; then
    echo "[OK] Found $model_count .pt model file(s)"
    echo "[START] AI object detection available"
else
    echo "[DIR] No .pt model files found"
    echo "[TIP] Place .pt files in ./models/ ./weights/ or current directory"
    echo "[INFO] Motion detection will be used as fallback"
fi

echo ""

# ============================================
# Tulis GUI script — pakai system python3
# gi ada di /usr/lib/python3/dist-packages
# ============================================
GUI_SCRIPT="/tmp/anpr_webview_gui.py"

cat > "$GUI_SCRIPT" << 'PYEOF'
#!/usr/bin/env python3
import sys
# Inject path agar gi ditemukan meski dipanggil dari venv context
sys.path.insert(0, '/usr/lib/python3/dist-packages')

import time
import urllib.request
import os
import signal

URL = "http://localhost:4000"
MAX_WAIT = 90

def wait_for_server():
    print("[GUI] Menunggu server siap...", flush=True)
    for i in range(MAX_WAIT):
        try:
            urllib.request.urlopen(URL, timeout=2)
            print("[GUI] Server siap! Membuka window...", flush=True)
            return True
        except Exception:
            time.sleep(1)
    print("[GUI] Timeout: server tidak merespons.", flush=True)
    return False

if not wait_for_server():
    sys.exit(1)

try:
    import gi
    gi.require_version('Gtk', '3.0')
    try:
        gi.require_version('WebKit2', '4.1')
    except ValueError:
        gi.require_version('WebKit2', '4.0')
    from gi.repository import Gtk, WebKit2
except ImportError as e:
    print(f"[GUI] ERROR: GTK tidak tersedia — {e}", flush=True)
    print("[GUI] Install: sudo apt install python3-gi gir1.2-gtk-3.0 gir1.2-webkit2-4.0", flush=True)
    sys.exit(1)

def on_destroy(widget):
    """Tutup window = matikan seluruh sistem."""
    parent_pid = os.getppid()
    try:
        os.kill(parent_pid, signal.SIGTERM)
    except Exception:
        pass
    Gtk.main_quit()

win = Gtk.Window()
win.set_title("CCTV System")
win.set_default_size(1280, 800)
win.connect("destroy", on_destroy)

webview = WebKit2.WebView()
webview.load_uri(URL)

scrolled = Gtk.ScrolledWindow()
scrolled.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
scrolled.add(webview)

vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
vbox.pack_start(scrolled, True, True, 0)
win.add(vbox)
win.show_all()

Gtk.main()
PYEOF

# ============================================
# Start Application
# ============================================
echo "============================================"
echo "[START] Starting CCTV System..."
echo "============================================"
echo ""
echo "[WEB] MULTI-SOURCE CCTV SYSTEM READY:"
echo "   [RTSP] Web interface: http://localhost:4000"
echo "   [STREAM] Video sources: RTSP/IP, Webcam, Streams, Files"
echo "   [AI] AI Detection: Universal .pt model support"
echo "   [MOB] Detection overlay: Toggleable bounding boxes"
echo "   [TIME]  Timing preservation: Original speed for all sources"
echo ""
echo "[CTRL] CONTROLS:"
echo "   [STOP]  Stop: Ctrl+C (graceful shutdown)"
echo "   [INFO] Restart: ./start.sh"
echo "   [STATS] Logs: Displayed below in real-time"
echo ""
echo "[GUI] Window akan muncul otomatis saat server siap..."
echo ""
echo "Press Ctrl+C to stop the server"
echo "--------------------------------------------"
echo ""

# Jalankan GUI di background dengan system python3
python3 "$GUI_SCRIPT" &
GUI_PID=$!

# Jalankan Flask di foreground dengan venv python
exec python app.py
