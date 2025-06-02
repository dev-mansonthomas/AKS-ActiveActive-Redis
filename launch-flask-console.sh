#!/usr/bin/env bash
source ./.venv/bin/activate
cd flask
python3 app.py &
PID=$!
echo "Flask Console PID : $PID "
URL="http://localhost:5000/"
echo "Opening Flask Console on $URL"
sleep 1

if [[ "$OSTYPE" == "darwin"* ]]; then
    open "$URL"    # macOS
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    xdg-open "$URL"  # Linux
else
    echo "❌ Unsupported OS."
fi