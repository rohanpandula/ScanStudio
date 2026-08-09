from __future__ import annotations

import logging
import os

import uvicorn

from .app import create_app
from .settings import Settings

logger = logging.getLogger(__name__)


def _isolate_process_group_if_requested() -> None:
    """Put the gateway and its engine child in a dedicated process group.

    The macOS host enables this before it starts the gateway.  That gives the
    host a process-tree-safe escalation target if graceful Uvicorn shutdown
    ever stalls.  Docker does not need it and leaves the option unset.
    """

    if os.getenv("SCANSTUDIO_WEB_ISOLATE_PROCESS_GROUP") != "1":
        return
    try:
        os.setsid()
    except (AttributeError, OSError) as exc:
        raise RuntimeError(
            "SCANSTUDIO_WEB_ISOLATE_PROCESS_GROUP requested, but a dedicated "
            "process group could not be created"
        ) from exc


def main() -> None:
    _isolate_process_group_if_requested()
    settings = Settings.from_env()
    server: uvicorn.Server | None = None

    def exit_on_engine_fatal(message: str) -> None:
        logger.error("stopping gateway after fatal engine failure: %s", message)
        if server is not None:
            server.should_exit = True

    # One worker is a correctness boundary: the process-local controller lease
    # and the one supervised engine must never be replicated behind a socket.
    config = uvicorn.Config(
        create_app(settings, on_engine_fatal=exit_on_engine_fatal),
        host=settings.bind_host,
        port=settings.port,
        workers=1,
        reload=False,
        proxy_headers=False,
        server_header=False,
    )
    server = uvicorn.Server(config)
    try:
        server.run()
    except KeyboardInterrupt:
        # Uvicorn has already completed its lifespan shutdown at this point;
        # keep an interactive Ctrl-C from printing a misleading traceback.
        pass


if __name__ == "__main__":
    main()
