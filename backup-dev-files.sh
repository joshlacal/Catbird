#!/bin/bash

# Catbird Project - Backup Development Files (Optional)
# This script creates a backup of development files in a separate directory

BACKUP_DIR="../Catbird-DevFiles-$(date +%Y%m%d-%H%M%S)"

echo "📦 Creating backup of development files..."
echo "   Backup location: $BACKUP_DIR"
echo ""

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Copy development markdown files
echo "📄 Backing up development documentation..."
mkdir -p "$BACKUP_DIR/docs"
cp -p CLAUDE.md "$BACKUP_DIR/docs/" 2>/dev/null || echo "  - CLAUDE.md not found"
cp -p *_PLAN.md "$BACKUP_DIR/docs/" 2>/dev/null || echo "  - No _PLAN files"
cp -p *_IMPLEMENTATION.md "$BACKUP_DIR/docs/" 2>/dev/null || echo "  - No _IMPLEMENTATION files"
cp -p *TODO*.md "$BACKUP_DIR/docs/" 2>/dev/null || echo "  - No TODO files"
cp -p BUGS*.md "$BACKUP_DIR/docs/" 2>/dev/null || echo "  - No BUGS files"

# Copy scripts
echo "🔧 Backing up helper scripts..."
mkdir -p "$BACKUP_DIR/scripts"
cp -p *.sh "$BACKUP_DIR/scripts/" 2>/dev/null || echo "  - No shell scripts"
cp -p TEST_*.swift "$BACKUP_DIR/scripts/" 2>/dev/null || echo "  - No test swift files"

# Copy screenshots
echo "🖼️  Backing up screenshots..."
mkdir -p "$BACKUP_DIR/screenshots"
cp -p *.png "$BACKUP_DIR/screenshots/" 2>/dev/null || echo "  - No screenshots"

# Copy logs
echo "📋 Backing up logs..."
mkdir -p "$BACKUP_DIR/logs"
cp -p *.txt "$BACKUP_DIR/logs/" 2>/dev/null || echo "  - No log files"

# Copy .claude directory
echo "🤖 Backing up .claude directory..."
cp -rp .claude "$BACKUP_DIR/" 2>/dev/null || echo "  - No .claude directory"

# Create an index file
cat > "$BACKUP_DIR/README.md" << EOF
# Catbird Development Files Backup

Created on: $(date)

This directory contains development files from the Catbird project that were excluded from the public repository.

## Contents:
- /docs/ - Development documentation (CLAUDE.md, TODOs, plans, etc.)
- /scripts/ - Helper scripts and test files
- /screenshots/ - Development screenshots
- /logs/ - Development logs
- /.claude/ - Claude-specific configuration

These files are kept for reference and can be safely stored outside the git repository.
EOF

echo ""
echo "✅ Backup complete!"
echo "📁 Files backed up to: $BACKUP_DIR"
echo ""
echo "You can now safely work with the public repository while keeping your development files."
