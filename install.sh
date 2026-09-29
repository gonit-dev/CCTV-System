#!/bin/bash

echo "======================================"
echo "🚀 YOLOv8 CCTV System Setup Script"
echo "======================================"
echo ""

# ============================================
# Disk Space & Cache Helper Functions
# ============================================
check_disk_space() {
    local required_mb=$1
    local path=${2:-"."}
    local available_mb=$(df -m "$path" 2>/dev/null | awk 'NR==2 {print $4}')

    if [ -z "$available_mb" ]; then
        echo "⚠️  WARNING: Cannot check disk space, continuing anyway..."
        return 0
    fi

    echo "💾 Disk space: ${available_mb}MB available (required: ${required_mb}MB)"

    if [ "$available_mb" -lt "$required_mb" ]; then
        echo ""
        echo "❌ ERROR: Tidak cukup ruang di perangkat (No space left on device)!"
        echo "   Available : ${available_mb}MB"
        echo "   Required  : ${required_mb}MB"
        echo ""
        echo "💡 Bebaskan ruang disk terlebih dahulu:"
        echo "   pip cache purge"
        echo "   sudo apt clean"
        echo "   sudo rm -rf /tmp/*"
        echo "   du -sh ~/.cache/pip"
        echo ""
        exit 1
    fi
}

clear_pip_cache() {
    echo "🧹 Clearing pip cache to free disk space..."
    ${PIP_CMD:-pip3} cache purge 2>/dev/null || true
}

pip_install() {
    local pkg="$1"
    if $PIP_CMD install --no-cache-dir "$pkg"; then
        return 0
    else
        local avail=$(df -m . 2>/dev/null | awk 'NR==2 {print $4}')
        if [ -n "$avail" ] && [ "$avail" -lt 300 ]; then
            echo "⚠️  Low disk space (${avail}MB). Clearing pip cache..."
            clear_pip_cache
            check_disk_space 500 "."
        fi
        echo "🔄 Retrying: $pkg..."
        $PIP_CMD install --no-cache-dir "$pkg"
        return $?
    fi
}

# Check minimum 5GB upfront (PyTorch ~2GB + YOLO models ~1GB + deps)
echo "🔍 Checking disk space (minimum 5GB required)..."
check_disk_space 5120 "."
echo ""

# Check Python version
echo "🐍 Checking Python version..."
python_version=$(python3 --version 2>/dev/null || python --version 2>/dev/null)
if [ $? -eq 0 ]; then
    echo "✅ Found: $python_version"
else
    echo "❌ Python not found. Please install Python 3.7+ first."
    exit 1
fi

# Check if pip is available
echo ""
echo "📦 Checking pip availability..."
if command -v pip3 &> /dev/null; then
    PIP_CMD="pip3"
elif command -v pip &> /dev/null; then
    PIP_CMD="pip"
else
    echo "❌ pip not found. Please install pip first."
    exit 1
fi
echo "✅ Found: $PIP_CMD"

# ============================================
# Install GTK WebKit2 (system-level)
# Dibutuhkan agar GUI window muncul otomatis
# tanpa membuka browser
# ============================================
echo ""
echo "🖥️  Installing GUI dependencies (GTK WebKit2)..."
if command -v apt-get &> /dev/null; then
    sudo apt-get update -qq
    # Coba webkit2 4.1 dulu, fallback ke 4.0
    if sudo apt-get install -y -q --no-install-recommends \
        python3-gi \
        python3-gi-cairo \
        gir1.2-gtk-3.0 \
        gir1.2-webkit2-4.1 2>/dev/null; then
        echo "✅ GTK WebKit2 4.1 installed"
    elif sudo apt-get install -y -q --no-install-recommends \
        python3-gi \
        python3-gi-cairo \
        gir1.2-gtk-3.0 \
        gir1.2-webkit2-4.0 2>/dev/null; then
        echo "✅ GTK WebKit2 4.0 installed"
    else
        echo "⚠️  WARNING: Gagal install GTK via apt"
        echo "   Coba manual: sudo apt install python3-gi gir1.2-gtk-3.0 gir1.2-webkit2-4.0"
    fi
elif command -v dnf &> /dev/null; then
    sudo dnf install -y python3-gobject webkit2gtk4.0 2>/dev/null && echo "✅ GTK WebKit2 installed (dnf)" || echo "⚠️  WARNING: Gagal install GTK via dnf"
elif command -v pacman &> /dev/null; then
    sudo pacman -S --noconfirm python-gobject webkit2gtk 2>/dev/null && echo "✅ GTK WebKit2 installed (pacman)" || echo "⚠️  WARNING: Gagal install GTK via pacman"
else
    echo "⚠️  Package manager tidak dikenali"
    echo "   Install manual: python3-gi + gir1.2-webkit2-4.0"
fi

# Verifikasi
if python3 -c "import sys; sys.path.insert(0,'/usr/lib/python3/dist-packages'); import gi" 2>/dev/null; then
    echo "✅ GTK gi module verified OK"
else
    echo "⚠️  gi module belum tersedia — GUI window mungkin tidak berfungsi"
fi

# Create virtual environment (recommended)
echo ""
echo "🔧 Setting up virtual environment (recommended)..."
read -p "Do you want to create a virtual environment? (y/N): " create_venv
if [[ $create_venv =~ ^[Yy]$ ]]; then
    echo "Creating virtual environment 'venv'..."
    python3 -m venv venv
    source venv/bin/activate
    echo "✅ Virtual environment created and activated"
    echo "💡 To activate later: source venv/bin/activate"
    PIP_CMD="pip"
else
    echo "⚠️  Installing globally (not recommended for production)"
fi

# Upgrade pip
echo ""
echo "⬆️  Upgrading pip..."
$PIP_CMD install --no-cache-dir --upgrade pip

# Install core dependencies
echo ""
echo "📦 Installing core dependencies..."
echo "This may take a few minutes for the first time..."

dependencies=(
    "opencv-python>=4.5.0"
    "numpy>=1.19.0"
    "flask>=2.0.0"
    "flask-socketio>=5.0.0"
    "onvif-zeep>=0.2.12"
    "ultralytics>=8.0.0"
    "yt-dlp>=2023.1.6"
    "Pillow>=8.0.0"
    "requests>=2.25.0"
    "psutil>=5.8.0"
)

for dep in "${dependencies[@]}"; do
    echo ""
    echo "Installing $dep..."
    if pip_install "$dep"; then
        echo "✅ $dep installed successfully"
    else
        echo "❌ Failed to install $dep"
        echo "💡 Try manually: $PIP_CMD install --no-cache-dir $dep"
    fi
done

# Install PyTorch with CUDA support (optional but recommended for performance)
echo ""
echo "🔥 GPU Acceleration Setup..."
read -p "Do you want to install PyTorch with CUDA support for GPU acceleration? (y/N): " install_cuda
if [[ $install_cuda =~ ^[Yy]$ ]]; then
    echo "Installing PyTorch with CUDA support..."
    echo "💡 This will download ~2GB of packages"

    # Check disk space before PyTorch download
    echo "🔍 Checking disk space for PyTorch (~2GB)..."
    check_disk_space 3072 "."

    if command -v nvidia-smi &> /dev/null; then
        cuda_version=$(nvidia-smi | grep "CUDA Version" | awk '{print $9}' | cut -d. -f1,2)
        echo "🔍 Detected CUDA version: $cuda_version"

        if [[ $cuda_version == "11."* ]]; then
            $PIP_CMD install --no-cache-dir torch torchvision --index-url https://download.pytorch.org/whl/cu118
        elif [[ $cuda_version == "12."* ]]; then
            $PIP_CMD install --no-cache-dir torch torchvision --index-url https://download.pytorch.org/whl/cu121
        else
            echo "⚠️  Unknown CUDA version, installing CPU version"
            $PIP_CMD install --no-cache-dir torch torchvision --index-url https://download.pytorch.org/whl/cpu
        fi
    else
        echo "🚫 NVIDIA GPU not detected, installing CPU version"
        $PIP_CMD install --no-cache-dir torch torchvision --index-url https://download.pytorch.org/whl/cpu
    fi
else
    echo "Installing CPU-only PyTorch (slower but compatible with all systems)"

    # Check disk space before PyTorch download
    echo "🔍 Checking disk space for PyTorch (~1.5GB)..."
    check_disk_space 2048 "."

    $PIP_CMD install --no-cache-dir torch torchvision --index-url https://download.pytorch.org/whl/cpu
fi

# Download YOLOv8 models
echo ""
echo "📥 Downloading YOLOv8 models..."
echo "💡 Models will be downloaded automatically on first use, but you can pre-download them:"

models=(
    "yolov8n.pt"
    "yolov8s.pt"
    "yolov8m.pt"
)

read -p "Download YOLOv8 models now? (y/N): " download_models
if [[ $download_models =~ ^[Yy]$ ]]; then
    # Each model ~6-25MB, check space
    check_disk_space 200 "."
    for model in "${models[@]}"; do
        if [ ! -f "$model" ]; then
            echo "Downloading $model..."
            python3 -c "
from ultralytics import YOLO
try:
    model = YOLO('$model')
    print('✅ $model downloaded successfully')
except Exception as e:
    print('❌ Failed to download $model:', e)
"
        else
            echo "✅ $model already exists"
        fi
    done
else
    echo "⏭️  Models will be downloaded automatically when needed"
fi

# Test yt-dlp with YouTube
echo ""
echo "📺 Testing yt-dlp with YouTube..."
read -p "Test yt-dlp with a sample YouTube video? (y/N): " test_ytdlp
if [[ $test_ytdlp =~ ^[Yy]$ ]]; then
    echo "Testing yt-dlp functionality..."
    python3 -c "
import yt_dlp

try:
    test_url = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ'
    ydl_opts = {
        'quiet': True,
        'no_warnings': True,
        'extract_flat': False,
    }
    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        info = ydl.extract_info(test_url, download=False)
        if info:
            print('✅ yt-dlp test successful')
            print(f'   Title: {info.get(\"title\", \"Unknown\")}')
            print(f'   Duration: {info.get(\"duration\", \"Unknown\")} seconds')
        else:
            print('❌ yt-dlp test failed: No info extracted')
except Exception as e:
    print(f'❌ yt-dlp test failed: {e}')
    print('💡 This might be due to network issues or YouTube blocking')
"
else
    echo "⏭️  yt-dlp test skipped"
fi

# Test installation
echo ""
echo "🧪 Testing installation..."
python3 -c "
import sys
from importlib.metadata import version
print('Testing imports...')

try:
    import cv2
    print('✅ OpenCV:', cv2.__version__)
except ImportError as e:
    print('❌ OpenCV failed:', e)

try:
    import numpy as np
    print('✅ NumPy:', np.__version__)
except ImportError as e:
    print('❌ NumPy failed:', e)

try:
    import flask
    print('✅ Flask:', version('flask'))
except ImportError as e:
    print('❌ Flask failed:', e)

try:
    import flask_socketio
    print('✅ Flask-SocketIO:', version('flask-socketio'))
except ImportError as e:
    print('❌ Flask-SocketIO failed:', e)

try:
    from ultralytics import YOLO
    print('✅ YOLOv8 (ultralytics): Available')
    import torch
    device = 'cuda' if torch.cuda.is_available() else 'cpu'
    print('🔥 PyTorch device:', device)
    model = YOLO('yolov8n.pt')
    print('✅ YOLOv8 model test: Success')
except ImportError as e:
    print('❌ YOLOv8 failed:', e)
except Exception as e:
    print('⚠️  YOLOv8 warning:', e)
    print('💡 This is normal on first run - models will download automatically')

try:
    from onvif import ONVIFCamera
    print('✅ ONVIF: Available')
except ImportError as e:
    print('❌ ONVIF failed:', e)

try:
    import yt_dlp
    print('✅ yt-dlp:', yt_dlp.version.__version__)
    print('   📺 YouTube Live streaming support enabled')
except ImportError as e:
    print('❌ yt-dlp failed:', e)
    print('💡 Install with: pip install yt-dlp')

try:
    import psutil
    memory = psutil.virtual_memory()
    print('✅ psutil: Available')
    print(f'   💾 System RAM: {memory.total // (1024**3)}GB total, {memory.available // (1024**3)}GB available')
    disk = psutil.disk_usage('.')
    print(f'   💿 Disk: {disk.free // (1024**3)}GB free of {disk.total // (1024**3)}GB total')
except ImportError as e:
    print('⚠️  psutil not available (optional for system monitoring)')

print('')
print('🎯 System Requirements Check:')
import platform
print(f'OS: {platform.system()} {platform.release()}')
print(f'Python: {sys.version}')
print(f'Architecture: {platform.machine()}')

try:
    import cv2
    cap = cv2.VideoCapture(0)
    if cap.isOpened():
        ret, frame = cap.read()
        print('📹 Webcam:', 'Available' if ret else 'Detected but cannot read frames')
        cap.release()
    else:
        print('📹 Webcam: Not detected')
except:
    print('📹 Webcam: Could not test')

try:
    import requests
    response = requests.get('https://www.google.com', timeout=5)
    print('🌐 Internet:', 'Connected' if response.status_code == 200 else 'Limited connectivity')
except:
    print('🌐 Internet: No connection or timeout')
"

echo ""
echo "======================================"
echo "🎉 Installation Complete!"
echo "======================================"
echo ""
echo "📋 Next Steps:"
echo "1. Start your CCTV system:"
echo "   ./start.sh"
echo ""
echo "2. GUI window akan muncul otomatis saat server siap"
echo "   (tidak perlu buka browser secara manual)"
echo ""
echo "3. Connect your camera using:"
echo "   • RTSP URL (IP cameras)"
echo "   • USB Webcam (auto-detected)"
echo "   • YouTube Live streams"
echo "   • Video files"
echo ""
echo "💡 Features Available:"
echo "• 🎥 RTSP/IP Camera support with ONVIF PTZ control"
echo "• 📹 USB/Built-in webcam auto-detection"
echo "• 📺 YouTube Live streaming (requires yt-dlp)"
echo "• 🎮 Twitch stream support"
echo "• 📁 Video file playback with timing control"
echo "• 🤖 YOLOv8 AI person detection"
echo "• 🎯 Auto person tracking (PTZ cameras)"
echo "• ⚡ Ultra low-latency streaming"
echo "• 🔴 Live stream timing preservation"
echo ""
echo "🔧 Model Performance Tips:"
echo "• yolov8n.pt: Fastest detection (~30 FPS)"
echo "• yolov8s.pt: Balanced speed/accuracy (~20 FPS)"
echo "• yolov8m.pt: Better accuracy (~15 FPS)"
echo "• yolov8l.pt: High accuracy (~10 FPS)"
echo "• GPU acceleration will be used automatically if available"
echo ""
echo "📺 YouTube Live Usage:"
echo "• Use format: https://www.youtube.com/watch?v=VIDEO_ID"
echo "• Or channel live: https://www.youtube.com/c/CHANNEL/live"
echo "• yt-dlp will extract direct stream URLs automatically"
echo ""
echo "🔧 Troubleshooting:"
echo "• Disk full error: pip cache purge && sudo apt clean"
echo "• If imports fail: pip install --no-cache-dir <package>"
echo "• For CUDA issues: install appropriate PyTorch version"
echo "• For YouTube issues: pip install --upgrade yt-dlp"
echo ""
echo "📚 Documentation:"
echo "• YOLOv8: https://docs.ultralytics.com/"
echo "• OpenCV: https://docs.opencv.org/"
echo "• ONVIF: https://www.onvif.org/"
echo "• yt-dlp: https://github.com/yt-dlp/yt-dlp"
echo ""
echo "🚀 Ready to start your AI-powered CCTV system!"
echo "======================================"
