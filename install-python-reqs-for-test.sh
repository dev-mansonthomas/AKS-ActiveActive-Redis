#!/bin/bash
echo "🔧 Installing Python dependencies in virtual environment (if not already active)..."
if [ -z "$VIRTUAL_ENV" ]; then
    echo "⚠️  No virtual environment detected. Creating one"
    python -m venv .venv
    source .venv/bin/activate
    pip install --upgrade pip
    echo "Update your IDE (PyCharm) : Settings, Project, Python Interpreter, Select existing, choose .venv in this project folder"
fi

echo "📦 Installing from requirements.txt..."
pip install -r requirements.txt