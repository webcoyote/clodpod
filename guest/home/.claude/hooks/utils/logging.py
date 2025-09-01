#!/usr/bin/env python3
"""
Shared logging utilities for Claude hooks.
Provides consistent JSONL logging functionality across all hooks.
"""

import json
from pathlib import Path
from typing import Any, Dict, Optional


def ensure_log_directory(log_dir: str = "logs") -> Path:
    """
    Ensure the log directory exists.
    
    Args:
        log_dir: Name of the log directory (default: "logs")
    
    Returns:
        Path object for the log directory
    """
    log_path = Path(log_dir)
    log_path.mkdir(parents=True, exist_ok=True)
    return log_path

def log_to_jsonl(
    data: Dict[str, Any], 
    log_filename: str,
    log_dir: str = "logs"
) -> None:
    """
    Append data as a single line to a JSONL file.
    
    Args:
        data: Dictionary to log
        log_filename: Name of the log file (e.g., 'user_prompt_submit.jsonl')
        log_dir: Name of the log directory (default: "logs")
    """
    log_path = ensure_log_directory(log_dir)
    log_file = log_path / log_filename
    
    with open(log_file, 'a') as f:
        json.dump(data, f)
        f.write('\n')

def copy_jsonl_file(
    source_path: str,
    dest_path: str
) -> None:
    """
    Copy a JSONL file to another location.

    Args:
        source_path: Path to the source JSONL file
        dest_path: Path for the destination JSONL file
    """
    ensure_log_directory(str(Path(dest_path).parent))

    with open(source_path, 'r') as src_file:
        content = src_file.read()
    with open(dest_path, 'w') as dest_file:
        dest_file.write(content)
