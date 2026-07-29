"""Internal logging helper.

A thin wrapper over the standard library's ``logging`` module so the rest of
this package can call ``get_logger(__name__)`` without depending on any host
application's logging configuration. A ``NullHandler`` is attached to the
package's root logger so that an application which never configures logging
gets no output and no "no handlers could be found" warning, per the standard
library's guidance for library authors.
"""

import logging

logging.getLogger("coolscanpy").addHandler(logging.NullHandler())


def get_logger(name: str | None = None) -> logging.Logger:
    """Return a logger namespaced under ``coolscanpy``.

    ``name`` is typically a module's ``__name__`` (already fully qualified as
    ``coolscanpy.<submodule>``), in which case it is used as-is. A bare,
    unqualified name is nested under the package logger instead.
    """
    if not name:
        return logging.getLogger("coolscanpy")
    if name == "coolscanpy" or name.startswith("coolscanpy."):
        return logging.getLogger(name)
    return logging.getLogger(f"coolscanpy.{name}")
