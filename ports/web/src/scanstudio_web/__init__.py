"""ScanStudio's simulator-only web gateway."""

from .app import create_app
from .settings import Settings

__all__ = ["Settings", "create_app"]
